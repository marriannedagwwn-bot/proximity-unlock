#include "common.h"
#include <aclapi.h>

namespace proximity {
bool Random(void* data, DWORD size) { return BCryptGenRandom(nullptr, static_cast<PUCHAR>(data), size, BCRYPT_USE_SYSTEM_PREFERRED_RNG) == 0; }
bool Hmac(const BYTE key[32], const void* data, DWORD size, BYTE mac[32]) {
    BCRYPT_ALG_HANDLE alg = nullptr;
    if(BCryptOpenAlgorithmProvider(&alg, BCRYPT_SHA256_ALGORITHM, nullptr, BCRYPT_ALG_HANDLE_HMAC_FLAG)) return false;
    auto status = BCryptHash(alg, const_cast<PUCHAR>(key), 32,
                            static_cast<PUCHAR>(const_cast<void*>(data)), size, mac, 32);
    BCryptCloseAlgorithmProvider(alg, 0); return status == 0;
}
bool ConstantEqual(const BYTE* a, const BYTE* b, size_t size) {
    volatile BYTE diff = 0; for(size_t i=0;i<size;++i) diff = static_cast<BYTE>(diff | (a[i]^b[i])); return diff == 0;
}
std::wstring SidString(PSID sid) {
    LPWSTR text=nullptr; if(!ConvertSidToStringSidW(sid,&text)) return {};
    std::wstring result(text); LocalFree(text); return result;
}
std::wstring CurrentSid() {
    HANDLE raw=nullptr; if(!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &raw)) return {};
    Handle token(raw); DWORD size=0; GetTokenInformation(token,TokenUser,nullptr,0,&size);
    std::vector<BYTE> value(size); if(!GetTokenInformation(token,TokenUser,value.data(),size,&size)) return {};
    return SidString(reinterpret_cast<TOKEN_USER*>(value.data())->User.Sid);
}
std::wstring KnownPath(REFKNOWNFOLDERID id) {
    PWSTR text=nullptr; if(FAILED(SHGetKnownFolderPath(id,0,nullptr,&text))) return {};
    std::wstring result(text); CoTaskMemFree(text); return result;
}
std::wstring UserDirectory() { return KnownPath(FOLDERID_LocalAppData)+L"\\ProximityUnlock"; }
std::wstring SystemDirectory() { return KnownPath(FOLDERID_ProgramData)+L"\\ProximityUnlock"; }
std::wstring InstallDirectory() { return KnownPath(FOLDERID_ProgramFiles)+L"\\ProximityUnlock"; }
std::wstring PipeName(DWORD session) { return L"\\\\.\\pipe\\ProximityUnlock-v1-"+std::to_wstring(session); }
bool ReadFileBytes(const std::wstring& path, std::vector<BYTE>& bytes) {
    Handle file(CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING,
                            FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
    if(!file) return false;
    BY_HANDLE_FILE_INFORMATION info{};
    if(!GetFileInformationByHandle(file,&info) || (info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)) return false;
    LARGE_INTEGER size{}; if(!GetFileSizeEx(file,&size) || size.QuadPart<=0 || size.QuadPart>16384) return false;
    bytes.resize(static_cast<size_t>(size.QuadPart)); DWORD n=0;
    return ReadFile(file,bytes.data(),static_cast<DWORD>(bytes.size()),&n,nullptr) && n==bytes.size();
}
bool SetPrivateDirectory(const std::wstring& path, const std::wstring& sddl) {
    PSECURITY_DESCRIPTOR sd=nullptr;
    if(!ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl.c_str(),SDDL_REVISION_1,&sd,nullptr)) return false;
    SECURITY_ATTRIBUTES sa{sizeof(sa),sd,FALSE};
    bool ok = CreateDirectoryW(path.c_str(),&sa) || GetLastError()==ERROR_ALREADY_EXISTS;
    Handle directory(CreateFileW(path.c_str(),READ_CONTROL|WRITE_DAC|WRITE_OWNER|FILE_READ_ATTRIBUTES,
        FILE_SHARE_READ,nullptr,OPEN_EXISTING,FILE_FLAG_BACKUP_SEMANTICS|FILE_FLAG_OPEN_REPARSE_POINT,nullptr));
    BY_HANDLE_FILE_INFORMATION info{};
    if(!directory || !GetFileInformationByHandle(directory,&info) ||
       (info.dwFileAttributes&FILE_ATTRIBUTE_REPARSE_POINT) || !(info.dwFileAttributes&FILE_ATTRIBUTE_DIRECTORY))ok=false;
    // Machine DPAPI is only safe with a trusted owner as well as a private DACL.
    // Reject a pre-created ordinary-user directory; its owner could restore access.
    if(ok && path==SystemDirectory()){
        PSID owner=nullptr;PSECURITY_DESCRIPTOR actual=nullptr;
        ok=GetSecurityInfo(directory,SE_FILE_OBJECT,OWNER_SECURITY_INFORMATION,&owner,nullptr,nullptr,nullptr,&actual)==ERROR_SUCCESS;
        if(ok){auto value=SidString(owner);ok=value==L"S-1-5-18" || value==L"S-1-5-32-544";}
        if(actual)LocalFree(actual);
    }
    if(ok){
        PACL dacl=nullptr;PSID owner=nullptr;BOOL present=FALSE,defaulted=FALSE;
        ok=GetSecurityDescriptorDacl(sd,&present,&dacl,&defaulted) && present &&
            GetSecurityDescriptorOwner(sd,&owner,&defaulted);
        if(ok)ok=SetSecurityInfo(directory,SE_FILE_OBJECT,DACL_SECURITY_INFORMATION|PROTECTED_DACL_SECURITY_INFORMATION|
            (owner?OWNER_SECURITY_INFORMATION:0),owner,nullptr,dacl,nullptr)==ERROR_SUCCESS;
    }
    LocalFree(sd); return ok;
}
bool ProtectFile(const std::wstring& path, const void* data, DWORD size, bool machine, const std::wstring& sddl) {
    DATA_BLOB in{size, static_cast<BYTE*>(const_cast<void*>(data))}, out{};
    if(!CryptProtectData(&in,L"ProximityUnlock local enrollment",nullptr,nullptr,nullptr,
                         CRYPTPROTECT_UI_FORBIDDEN|(machine?CRYPTPROTECT_LOCAL_MACHINE:0),&out)) return false;
    PSECURITY_DESCRIPTOR sd=nullptr;
    bool ok=ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl.c_str(),SDDL_REVISION_1,&sd,nullptr)!=FALSE;
    if(ok) {
        SECURITY_ATTRIBUTES sa{sizeof(sa),sd,FALSE};
        // Replace a new temporary file atomically. Never follow a pre-existing reparse point.
        std::wstring temporary=path+L".new";
        DeleteFileW(temporary.c_str());
        Handle file(CreateFileW(temporary.c_str(),GENERIC_WRITE,0,&sa,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,nullptr));
        DWORD n=0; ok=file && WriteFile(file,out.pbData,out.cbData,&n,nullptr) && n==out.cbData && FlushFileBuffers(file);
    }
    if(ok) ok=MoveFileExW((path+L".new").c_str(),path.c_str(),MOVEFILE_REPLACE_EXISTING|MOVEFILE_WRITE_THROUGH)!=FALSE;
    if(!ok) DeleteFileW((path+L".new").c_str());
    if(sd) LocalFree(sd); SecureZeroMemory(out.pbData,out.cbData); LocalFree(out.pbData); return ok;
}
bool UnprotectFile(const std::wstring& path, void* data, DWORD size) {
    std::vector<BYTE> encrypted; if(!ReadFileBytes(path,encrypted)) return false;
    DATA_BLOB in{static_cast<DWORD>(encrypted.size()),encrypted.data()},out{};
    if(!CryptUnprotectData(&in,nullptr,nullptr,nullptr,nullptr,CRYPTPROTECT_UI_FORBIDDEN,&out)) return false;
    bool ok=out.cbData==size; if(ok) memcpy(data,out.pbData,size);
    SecureZeroMemory(out.pbData,out.cbData); LocalFree(out.pbData); return ok;
}
bool ReadUser(UserEnrollment& user) {
    return UnprotectFile(UserDirectory()+L"\\enrollment.bin",&user,sizeof(user)) &&
        !memcmp(user.magic,"PRXUSER1",8) && user.version==1 && user.keyId && user.sid[191]==0 && CurrentSid()==user.sid;
}
bool ReadSystem(SystemEnrollment& system) {
    // Only the SYSTEM provider may read the machine-protected password envelope.
    return IsSystem() && UnprotectFile(SystemDirectory()+L"\\enrollment.bin",&system,sizeof(system)) &&
        !memcmp(system.user.magic,"PRXUSER1",8) && system.user.version==1 && system.user.keyId &&
        system.user.sid[191]==0 && system.username[255]==0 && system.domain[255]==0 && system.password[511]==0;
}
bool VerificationAllows(DWORD keyId,DWORD verifiedKeyId,bool allowPending){
    return keyId && (keyId==verifiedKeyId || (allowPending && verifiedKeyId==0));
}
bool VerificationProofMatches(DWORD submittedKeyId,DWORD storedKeyId,DWORD verifiedKeyId,
                              bool emptyPassword,NTSTATUS status,NTSTATUS substatus){
    return submittedKeyId && submittedKeyId==storedKeyId && verifiedKeyId==0 && emptyPassword && status==0 && substatus==0;
}
EnrollmentLock::EnrollmentLock(){
    PSECURITY_DESCRIPTOR sd=nullptr;
    if(!ConvertStringSecurityDescriptorToSecurityDescriptorW(L"O:BAD:P(A;;GA;;;SY)(A;;GA;;;BA)",SDDL_REVISION_1,&sd,nullptr))return;
    SECURITY_ATTRIBUTES sa{sizeof(sa),sd,FALSE};mutex.h=CreateMutexW(&sa,FALSE,L"Global\\ProximityUnlockEnrollment-v1");LocalFree(sd);
    if(!mutex)return;
    PSID owner=nullptr;PSECURITY_DESCRIPTOR actual=nullptr;
    bool trusted=GetSecurityInfo(mutex,SE_KERNEL_OBJECT,OWNER_SECURITY_INFORMATION,&owner,nullptr,nullptr,nullptr,&actual)==ERROR_SUCCESS;
    if(trusted){auto value=SidString(owner);trusted=value==L"S-1-5-18" || value==L"S-1-5-32-544";}
    if(actual)LocalFree(actual);if(!trusted)return;
    DWORD result=WaitForSingleObject(mutex,1000);locked=result==WAIT_OBJECT_0 || result==WAIT_ABANDONED;
}
EnrollmentLock::~EnrollmentLock(){if(locked)ReleaseMutex(mutex);}
bool RegistryEnabled(const UserEnrollment& user,bool allowPending) {
    HKEY key=nullptr; if(RegOpenKeyExW(HKEY_LOCAL_MACHINE,kRegistry,0,KEY_READ|KEY_WOW64_64KEY,&key)) return false;
    wchar_t sid[192]{}; DWORD size=sizeof(sid),type=0,id=0,idSize=sizeof(id);
    bool ok=RegQueryValueExW(key,L"TargetSid",nullptr,&type,reinterpret_cast<BYTE*>(sid),&size)==ERROR_SUCCESS &&
        type==REG_SZ && sid[191]==0 && std::wstring(sid)==user.sid;
    type=0; ok=ok && RegQueryValueExW(key,L"KeyId",nullptr,&type,reinterpret_cast<BYTE*>(&id),&idSize)==ERROR_SUCCESS && type==REG_DWORD && id==user.keyId;
    DWORD verified=0;idSize=sizeof(verified);type=0;
    ok=ok && RegQueryValueExW(key,L"VerifiedKeyId",nullptr,&type,reinterpret_cast<BYTE*>(&verified),&idSize)==ERROR_SUCCESS &&
        type==REG_DWORD && VerificationAllows(id,verified,allowPending);
    RegCloseKey(key);
    std::wstring com=L"SOFTWARE\\Classes\\CLSID\\"+std::wstring(kClsid)+L"\\InprocServer32";
    wchar_t path[MAX_PATH]{}; size=sizeof(path); key=nullptr;
    if(RegOpenKeyExW(HKEY_LOCAL_MACHINE,com.c_str(),0,KEY_READ|KEY_WOW64_64KEY,&key)) return false;
    type=0; ok=ok && RegQueryValueExW(key,nullptr,nullptr,&type,reinterpret_cast<BYTE*>(path),&size)==ERROR_SUCCESS && type==REG_SZ &&
        _wcsicmp(path,(InstallDirectory()+L"\\ProximityCredentialProvider.dll").c_str())==0;
    RegCloseKey(key);
    if(!ok || GetFileAttributesW(path)==INVALID_FILE_ATTRIBUTES)return false;
    std::wstring registration=L"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Authentication\\Credential Providers\\"+std::wstring(kClsid);
    key=nullptr;if(RegOpenKeyExW(HKEY_LOCAL_MACHINE,registration.c_str(),0,KEY_READ|KEY_WOW64_64KEY,&key))return false;
    DWORD disabled=0;size=sizeof(disabled);type=0;
    LSTATUS status=RegQueryValueExW(key,L"Disabled",nullptr,&type,reinterpret_cast<BYTE*>(&disabled),&size);
    ok=status==ERROR_FILE_NOT_FOUND || (status==ERROR_SUCCESS && type==REG_DWORD && disabled==0);
    RegCloseKey(key);return ok;
}
bool MarkConsoleVerified(DWORD submittedKeyId,const std::wstring& sid,DWORD session,NTSTATUS status,NTSTATUS substatus){
    if(!IsSystem() || status || substatus)return false;
    EnrollmentLock guard;if(!guard)return false;
    Secret stored;
    if(!ReadSystem(stored.value) || !RegistryEnabled(stored.value.user,true) || sid!=stored.value.user.sid ||
        (!ConsoleTarget(sid.c_str(),session,true) && !ConsoleTarget(sid.c_str(),session,false)))return false;
    HKEY key=nullptr;if(RegOpenKeyExW(HKEY_LOCAL_MACHINE,kRegistry,0,KEY_READ|KEY_SET_VALUE|KEY_WOW64_64KEY,&key))return false;
    DWORD current=0,verified=0,type=0,size=sizeof(current);
    bool ok=RegQueryValueExW(key,L"KeyId",nullptr,&type,reinterpret_cast<BYTE*>(&current),&size)==ERROR_SUCCESS && type==REG_DWORD;
    type=0;size=sizeof(verified);
    ok=ok && RegQueryValueExW(key,L"VerifiedKeyId",nullptr,&type,reinterpret_cast<BYTE*>(&verified),&size)==ERROR_SUCCESS && type==REG_DWORD &&
        VerificationProofMatches(submittedKeyId,current,verified,stored.value.password[0]==0,status,substatus) && current==stored.value.user.keyId;
    if(ok)ok=RegSetValueExW(key,L"VerifiedKeyId",0,REG_DWORD,reinterpret_cast<const BYTE*>(&submittedKeyId),sizeof(submittedKeyId))==ERROR_SUCCESS;
    RegCloseKey(key);return ok;
}
bool ConsoleAccount(std::wstring& username,std::wstring& domain,std::wstring& sid,DWORD& session) {
    session=WTSGetActiveConsoleSessionId(); if(session==0xffffffff) return false;
    LPWSTR text=nullptr; DWORD bytes=0;
    if(!WTSQuerySessionInformationW(WTS_CURRENT_SERVER_HANDLE,session,WTSUserName,&text,&bytes)) return false;
    username=text; WTSFreeMemory(text); if(username.empty()) return false;
    if(!WTSQuerySessionInformationW(WTS_CURRENT_SERVER_HANDLE,session,WTSDomainName,&text,&bytes)) return false;
    domain=text; WTSFreeMemory(text);
    wchar_t computer[MAX_COMPUTERNAME_LENGTH+1]{}; DWORD length=MAX_COMPUTERNAME_LENGTH+1;
    if(!GetComputerNameW(computer,&length) || _wcsicmp(domain.c_str(),computer)) return false;
    std::wstring account=domain+L"\\"+username;
    DWORD sidSize=0,domainSize=0; SID_NAME_USE use{};
    LookupAccountNameW(nullptr,account.c_str(),nullptr,&sidSize,nullptr,&domainSize,&use);
    std::vector<BYTE> sidBytes(sidSize); std::vector<wchar_t> foundDomain(domainSize);
    if(!sidSize || !LookupAccountNameW(nullptr,account.c_str(),sidBytes.data(),&sidSize,foundDomain.data(),&domainSize,&use) || use!=SidTypeUser) return false;
    sid=SidString(sidBytes.data()); return !sid.empty();
}
bool ConsoleTarget(const wchar_t* expectedSid,DWORD session,bool locked) {
    std::wstring username,domain,sid; DWORD active=0;
    if(!ConsoleAccount(username,domain,sid,active) || active!=session || sid!=expectedSid) return false;
    LPWSTR text=nullptr; DWORD bytes=0;
    if(!WTSQuerySessionInformationW(WTS_CURRENT_SERVER_HANDLE,session,WTSClientProtocolType,&text,&bytes)) return false;
    bool local=bytes>=sizeof(USHORT) && *reinterpret_cast<USHORT*>(text)==0; WTSFreeMemory(text);
    if(!local || !WTSQuerySessionInformationW(WTS_CURRENT_SERVER_HANDLE,session,WTSSessionInfoEx,&text,&bytes)) return false;
    bool ok=false;
    if(bytes>=sizeof(WTSINFOEXW)) {
        auto info=reinterpret_cast<WTSINFOEXW*>(text);
        ok=info->Level==1 && info->Data.WTSInfoExLevel1.SessionId==session &&
            info->Data.WTSInfoExLevel1.SessionState==WTSActive &&
            info->Data.WTSInfoExLevel1.SessionFlags==(locked?WTS_SESSIONSTATE_LOCK:WTS_SESSIONSTATE_UNLOCK);
    }
    WTSFreeMemory(text); return ok;
}
bool ConsoleTargetForInitialization(const wchar_t* expectedSid,DWORD session){
    // LogonUI can initialize while the exact existing console is transitioning
    // into the lock screen. Requests and serialization still require locked.
    return ConsoleTarget(expectedSid,session,true) || ConsoleTarget(expectedSid,session,false);
}
bool IsSystem() { return CurrentSid()==L"S-1-5-18"; }
bool IsAdministrator() {
    SID_IDENTIFIER_AUTHORITY auth=SECURITY_NT_AUTHORITY; PSID sid=nullptr; BOOL member=FALSE;
    if(AllocateAndInitializeSid(&auth,2,SECURITY_BUILTIN_DOMAIN_RID,DOMAIN_ALIAS_RID_ADMINS,0,0,0,0,0,0,&sid)) {
        CheckTokenMembership(nullptr,sid,&member); FreeSid(sid);
    } return member!=FALSE;
}
void NativeTrace(const wchar_t* stage,DWORD error,HRESULT result,NTSTATUS status,NTSTATUS substatus,DWORD detail){
    // Only the SYSTEM provider records fixed stage names and numeric outcomes.
    // No credential, account SID, key, challenge or request bytes are recorded.
    if(!IsSystem())return;
    HKEY key=nullptr;if(RegOpenKeyExW(HKEY_LOCAL_MACHINE,kRegistry,0,KEY_SET_VALUE|KEY_WOW64_64KEY,&key))return;
    auto number=[&](const wchar_t* name,DWORD value){RegSetValueExW(key,name,0,REG_DWORD,reinterpret_cast<const BYTE*>(&value),sizeof(value));};
    auto tick=GetTickCount64();DWORD session=0xffffffff;ProcessIdToSessionId(GetCurrentProcessId(),&session);
    RegSetValueExW(key,L"DiagnosticStage",0,REG_SZ,reinterpret_cast<const BYTE*>(stage),static_cast<DWORD>((wcslen(stage)+1)*2));
    number(L"DiagnosticWin32",error);number(L"DiagnosticHRESULT",static_cast<DWORD>(result));
    number(L"DiagnosticNTSTATUS",static_cast<DWORD>(status));number(L"DiagnosticSubstatus",static_cast<DWORD>(substatus));
    number(L"DiagnosticDetail",detail);number(L"DiagnosticProcessId",GetCurrentProcessId());number(L"DiagnosticSession",session);
    // A bounded slot for each fixed stage retains prior checkpoints even after
    // the pipe begins listening again. Its PID distinguishes old LogonUI state.
    std::wstring prefix=L"Diagnostic."+std::wstring(stage);
    RegSetValueExW(key,(prefix+L".Tick").c_str(),0,REG_QWORD,reinterpret_cast<const BYTE*>(&tick),sizeof(tick));
    number((prefix+L".PID").c_str(),GetCurrentProcessId());number((prefix+L".Session").c_str(),session);number((prefix+L".Win32").c_str(),error);
    number((prefix+L".HRESULT").c_str(),static_cast<DWORD>(result));number((prefix+L".Detail").c_str(),detail);
    if(!wcscmp(stage,L"ReportResult")){
        number(L"Diagnostic.ReportResult.NTSTATUS",static_cast<DWORD>(status));
        number(L"Diagnostic.ReportResult.Substatus",static_cast<DWORD>(substatus));
    }
    RegSetValueExW(key,L"DiagnosticTick",0,REG_QWORD,reinterpret_cast<const BYTE*>(&tick),sizeof(tick));RegCloseKey(key);
}
bool Transfer(HANDLE pipe,void* data,DWORD size,bool writing,DWORD timeout) {
    Handle event(CreateEventW(nullptr,TRUE,FALSE,nullptr)); if(!event) return false;
    OVERLAPPED over{}; over.hEvent=event; DWORD n=0;
    BOOL ok=writing?WriteFile(pipe,data,size,&n,&over):ReadFile(pipe,data,size,&n,&over);
    if(!ok && GetLastError()==ERROR_IO_PENDING) {
        if(WaitForSingleObject(event,timeout)!=WAIT_OBJECT_0) {
            CancelIoEx(pipe,&over); GetOverlappedResult(pipe,&over,&n,TRUE);SetLastError(ERROR_TIMEOUT); return false;
        }
        ok=GetOverlappedResult(pipe,&over,&n,FALSE);
    }
    if(ok && n!=size){SetLastError(ERROR_INVALID_DATA);return false;}return ok!=FALSE;
}
bool RequestUnlock(RequestDiagnostic* diagnostic) {
    auto outcome=[&](const char* stage,DWORD error){if(diagnostic){diagnostic->stage=stage;diagnostic->error=error?error:ERROR_GEN_FAILURE;}return false;};
    UserEnrollment user{};
    struct Wipe { UserEnrollment& value; ~Wipe(){SecureZeroMemory(&value,sizeof(value));} } wipe{user};
    // Explicit local helper also performs provisional console validation. BLE
    // availability and phone-key display require VerifiedKeyId independently.
    if(!ReadUser(user))return outcome("load-user",ERROR_INVALID_DATA);
    if(!RegistryEnabled(user,true))return outcome("registration",ERROR_ACCESS_DENIED);
    DWORD session=0;if(!ProcessIdToSessionId(GetCurrentProcessId(),&session))return outcome("process-session",GetLastError());
    if(!ConsoleTarget(user.sid,session,true))return outcome("target-locked",ERROR_ACCESS_DENIED);
    Handle pipe(CreateFileW(PipeName(session).c_str(),GENERIC_READ|GENERIC_WRITE,0,nullptr,OPEN_EXISTING,
        FILE_FLAG_OVERLAPPED|SECURITY_SQOS_PRESENT|SECURITY_IDENTIFICATION,nullptr));
    if(!pipe)return outcome("pipe-open",GetLastError());
    Challenge challenge{}; BYTE expected[32]{};
    if(!Transfer(pipe,&challenge,sizeof(challenge),false))return outcome("challenge-read",GetLastError());
    if(memcmp(challenge.magic,"PRXCHAL1",8) || challenge.version!=1 ||
       challenge.keyId!=user.keyId || challenge.session!=session || challenge.sid[191]!=0 || std::wstring(challenge.sid)!=user.sid ||
       challenge.expires>GetTickCount64()+2200)return outcome("challenge-format",ERROR_INVALID_DATA);
    if(challenge.expires<GetTickCount64())return outcome("challenge-expired",ERROR_TIMEOUT);
    if(!Hmac(user.ipc,&challenge,offsetof(Challenge,mac),expected) || !ConstantEqual(expected,challenge.mac,32))return outcome("challenge-mac",ERROR_ACCESS_DENIED);
    // Domain separation: request is HMAC of server's entire authenticated challenge.
    Request request{}; memcpy(request.magic,"PRXREQ01",8);
    std::vector<BYTE> message(sizeof(request.magic)+sizeof(challenge));
    memcpy(message.data(),request.magic,8); memcpy(message.data()+8,&challenge,sizeof(challenge));
    if(!Hmac(user.ipc,message.data(),static_cast<DWORD>(message.size()),request.mac))return outcome("request-mac",ERROR_INVALID_DATA);
    if(!Transfer(pipe,&request,sizeof(request),true))return outcome("request-write",GetLastError());
    BYTE accepted=0;if(!Transfer(pipe,&accepted,1,false))return outcome("ack-read",GetLastError());
    if(accepted!=1)return outcome("ack-rejected",ERROR_ACCESS_DENIED);
    // Submission is not success. Only an exact WTS active console unlock is success.
    ULONGLONG deadline=GetTickCount64()+4300;
    do {
        if(ConsoleTarget(user.sid,session,false)){
            if(diagnostic){diagnostic->stage="confirmed-unlocked";diagnostic->error=0;}return true;
        }
        if(WTSGetActiveConsoleSessionId()!=session)return outcome("target-changed",ERROR_ACCESS_DENIED);
        Sleep(50);
    } while(GetTickCount64()<deadline);
    return outcome("confirm-timeout",ERROR_TIMEOUT);
}
HRESULT Serialize(const SystemEnrollment& secret,CREDENTIAL_PROVIDER_USAGE_SCENARIO scenario,
                  CREDENTIAL_PROVIDER_CREDENTIAL_SERIALIZATION* result) {
    LSA_HANDLE lsa=nullptr; NTSTATUS status=LsaConnectUntrusted(&lsa);
    if(status) return HRESULT_FROM_WIN32(LsaNtStatusToWinError(status));
    char name[]="Negotiate"; LSA_STRING package{9,10,name}; ULONG auth=0;
    status=LsaLookupAuthenticationPackage(lsa,&package,&auth); LsaDeregisterLogonProcess(lsa);
    if(status) return HRESULT_FROM_WIN32(LsaNtStatusToWinError(status));
    // KERB_INTERACTIVE_UNLOCK_LOGON: packed UNICODE_STRING buffers are offsets,
    // not live pointers. Winlogon/LSA perform the actual account authentication.
    std::vector<wchar_t> protectedPassword;
    const wchar_t* password=secret.password;
    // Match Microsoft's ProtectIfNecessaryAndCopyPassword: an empty password is
    // copied as empty, not CredProtect-wrapped into a nonempty credential.
    if(scenario==CPUS_LOGON && password[0]){
        DWORD length=0;
        CredProtectW(FALSE,const_cast<PWSTR>(password),static_cast<DWORD>(wcslen(password)+1),nullptr,&length,nullptr);
        if(GetLastError()!=ERROR_INSUFFICIENT_BUFFER || !length)return HRESULT_FROM_WIN32(GetLastError());
        protectedPassword.resize(length);
        if(!CredProtectW(FALSE,const_cast<PWSTR>(password),static_cast<DWORD>(wcslen(password)+1),protectedPassword.data(),&length,nullptr))return HRESULT_FROM_WIN32(GetLastError());
        password=protectedPassword.data();
    }
    size_t domainBytes=wcslen(secret.domain)*sizeof(wchar_t), userBytes=wcslen(secret.username)*sizeof(wchar_t), passwordBytes=wcslen(password)*sizeof(wchar_t);
    size_t total=sizeof(KERB_INTERACTIVE_UNLOCK_LOGON)+domainBytes+userBytes+passwordBytes;
    auto packed=static_cast<BYTE*>(CoTaskMemAlloc(total));
    if(!packed){if(!protectedPassword.empty())SecureZeroMemory(protectedPassword.data(),protectedPassword.size()*2);return E_OUTOFMEMORY;}
    SecureZeroMemory(packed,total); auto logon=reinterpret_cast<KERB_INTERACTIVE_UNLOCK_LOGON*>(packed);
    logon->Logon.MessageType=scenario==CPUS_UNLOCK_WORKSTATION?KerbWorkstationUnlockLogon:KerbInteractiveLogon;
    size_t offset=sizeof(*logon);
    auto copy=[&](UNICODE_STRING& field,const wchar_t* text,size_t count){
        field.Length=field.MaximumLength=static_cast<USHORT>(count); field.Buffer=reinterpret_cast<PWSTR>(offset);
        memcpy(packed+offset,text,count); offset+=count;
    };
    copy(logon->Logon.LogonDomainName,secret.domain,domainBytes);
    copy(logon->Logon.UserName,secret.username,userBytes);
    copy(logon->Logon.Password,password,passwordBytes);
    if(!protectedPassword.empty())SecureZeroMemory(protectedPassword.data(),protectedPassword.size()*2);
    result->ulAuthenticationPackage=auth; result->clsidCredentialProvider=kProviderClsid;
    result->cbSerialization=static_cast<ULONG>(total); result->rgbSerialization=packed; return S_OK;
}
}
