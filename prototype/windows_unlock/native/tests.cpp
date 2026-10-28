#include "common.h"
#include <cstdio>

using namespace proximity;
static unsigned checks=0;
#define CHECK(expression) do { ++checks; if(!(expression)){fwprintf(stderr,L"Native check failed at line %u\n",__LINE__);return false;} } while(0)

static bool CryptoAndStorage(){
    BYTE key[32]{},mac[32]{};memset(key,0x0b,20);
    const BYTE expected[32]={0xb0,0x34,0x4c,0x61,0xd8,0xdb,0x38,0x53,0x5c,0xa8,0xaf,0xce,0xaf,0x0b,0xf1,0x2b,
        0x88,0x1d,0xc2,0x00,0xc9,0x83,0x3d,0xa7,0x26,0xe9,0x37,0x6c,0x2e,0x32,0xcf,0xf7};
    CHECK(Hmac(key,"Hi There",8,mac));CHECK(ConstantEqual(mac,expected,32));mac[3]^=1;CHECK(!ConstantEqual(mac,expected,32));
    BYTE random[32]{};CHECK(Random(random,32));BYTE zero[32]{};CHECK(!ConstantEqual(random,zero,32));
    const char fixture[]="Non-secret DPAPI verification fixture";
    DATA_BLOB plain{sizeof(fixture),reinterpret_cast<BYTE*>(const_cast<char*>(fixture))},encrypted{},decrypted{};
    CHECK(CryptProtectData(&plain,L"ProximityUnlock native non-secret test",nullptr,nullptr,nullptr,CRYPTPROTECT_UI_FORBIDDEN,&encrypted));
    CHECK(CryptUnprotectData(&encrypted,nullptr,nullptr,nullptr,nullptr,CRYPTPROTECT_UI_FORBIDDEN,&decrypted));
    CHECK(decrypted.cbData==sizeof(fixture) && !memcmp(decrypted.pbData,fixture,sizeof(fixture)));
    SecureZeroMemory(decrypted.pbData,decrypted.cbData);LocalFree(decrypted.pbData);
    encrypted.pbData[encrypted.cbData-1]^=1;
    CHECK(!CryptUnprotectData(&encrypted,nullptr,nullptr,nullptr,nullptr,CRYPTPROTECT_UI_FORBIDDEN,&decrypted));LocalFree(encrypted.pbData);
    return true;
}
static bool Serialization(){
    Secret secret;wcscpy_s(secret.value.domain,L"FIXTURE-PC");wcscpy_s(secret.value.username,L"FixtureUser");
    wcscpy_s(secret.value.password,L"FixtureOnly-NotARealPassword");
    CREDENTIAL_PROVIDER_CREDENTIAL_SERIALIZATION result{};
    CHECK(SUCCEEDED(Serialize(secret.value,CPUS_UNLOCK_WORKSTATION,&result)));
    CHECK(result.clsidCredentialProvider==kProviderClsid && result.cbSerialization>sizeof(KERB_INTERACTIVE_UNLOCK_LOGON));
    auto logon=reinterpret_cast<KERB_INTERACTIVE_UNLOCK_LOGON*>(result.rgbSerialization);
    CHECK(logon->Logon.MessageType==KerbWorkstationUnlockLogon);
    CHECK(logon->LogonId.HighPart==0 && logon->LogonId.LowPart==0);
    size_t offset=sizeof(*logon);
    auto field=[&](const UNICODE_STRING& value,const wchar_t* text){
        size_t bytes=wcslen(text)*2;
        bool ok=reinterpret_cast<size_t>(value.Buffer)==offset && value.Length==bytes && value.MaximumLength==bytes &&
            offset+bytes<=result.cbSerialization && !memcmp(result.rgbSerialization+offset,text,bytes);
        offset+=bytes;return ok;
    };
    CHECK(field(logon->Logon.LogonDomainName,secret.value.domain));CHECK(field(logon->Logon.UserName,secret.value.username));
    CHECK(field(logon->Logon.Password,secret.value.password));CHECK(offset==result.cbSerialization);
    SecureZeroMemory(result.rgbSerialization,result.cbSerialization);CoTaskMemFree(result.rgbSerialization);
    result={};CHECK(SUCCEEDED(Serialize(secret.value,CPUS_LOGON,&result)));
    logon=reinterpret_cast<KERB_INTERACTIVE_UNLOCK_LOGON*>(result.rgbSerialization);
    CHECK(logon->Logon.MessageType==KerbInteractiveLogon);
    auto password=reinterpret_cast<wchar_t*>(result.rgbSerialization+reinterpret_cast<size_t>(logon->Logon.Password.Buffer));
    std::wstring protectedText(password,logon->Logon.Password.Length/2);CRED_PROTECTION_TYPE type=CredUnprotected;
    CHECK(CredIsProtectedW(protectedText.data(),&type) && type!=CredUnprotected);
    SecureZeroMemory(protectedText.data(),protectedText.size()*2);
    SecureZeroMemory(result.rgbSerialization,result.cbSerialization);CoTaskMemFree(result.rgbSerialization);return true;
}
static bool EmptySerialization(){
    Secret secret;wcscpy_s(secret.value.domain,L"FIXTURE-PC");wcscpy_s(secret.value.username,L"FixtureUser");
    for(auto scenario:{CPUS_LOGON,CPUS_UNLOCK_WORKSTATION}){
        CREDENTIAL_PROVIDER_CREDENTIAL_SERIALIZATION result{};
        CHECK(SUCCEEDED(Serialize(secret.value,scenario,&result)));
        auto logon=reinterpret_cast<KERB_INTERACTIVE_UNLOCK_LOGON*>(result.rgbSerialization);
        size_t end=sizeof(*logon)+(wcslen(secret.value.domain)+wcslen(secret.value.username))*2;
        CHECK(result.cbSerialization==end);
        CHECK(logon->Logon.MessageType==(scenario==CPUS_LOGON?KerbInteractiveLogon:KerbWorkstationUnlockLogon));
        CHECK(logon->Logon.Password.Length==0 && logon->Logon.Password.MaximumLength==0);
        CHECK(reinterpret_cast<size_t>(logon->Logon.Password.Buffer)==end);
        CHECK(result.clsidCredentialProvider==kProviderClsid);
        SecureZeroMemory(result.rgbSerialization,result.cbSerialization);CoTaskMemFree(result.rgbSerialization);
    }
    return true;
}
static bool VerificationGates(){
    VerificationSubmission actual,sibling;
    actual.Serialized(42,true);
    CHECK(sibling.Consume()==0);
    CHECK(actual.Consume()==42);
    CHECK(actual.Consume()==0);
    actual.Serialized(43,false);CHECK(actual.Consume()==0);
    {VerificationSubmission old;old.Serialized(44,true);}
    VerificationSubmission replacement;CHECK(replacement.Consume()==0);
    CHECK(!VerificationAllows(0,0,true));
    CHECK(!VerificationAllows(42,0,false));
    CHECK(VerificationAllows(42,0,true));
    CHECK(VerificationAllows(42,42,false));
    CHECK(!VerificationAllows(42,41,true));
    CHECK(VerificationProofMatches(42,42,0,true,0,0));
    CHECK(!VerificationProofMatches(41,42,0,true,0,0));
    CHECK(!VerificationProofMatches(42,41,0,true,0,0));
    CHECK(!VerificationProofMatches(42,42,41,true,0,0));
    CHECK(!VerificationProofMatches(42,42,0,false,0,0));
    CHECK(!VerificationProofMatches(42,42,0,true,static_cast<NTSTATUS>(0xc000006d),0));
    CHECK(!VerificationProofMatches(42,42,0,true,0,static_cast<NTSTATUS>(0xc000006a)));
    CHECK(!MarkConsoleVerified(42,CurrentSid(),WTSGetActiveConsoleSessionId(),0,0));
    return true;
}
class Events final:public ICredentialProviderEvents {
    ULONG refs=1;
public:
    ULONG calls=0;
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid,void** out) override {
        if(!out)return E_POINTER;*out=nullptr;if(iid!=IID_IUnknown && iid!=IID_ICredentialProviderEvents)return E_NOINTERFACE;
        *out=static_cast<ICredentialProviderEvents*>(this);AddRef();return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef() override{return ++refs;}
    ULONG STDMETHODCALLTYPE Release() override{ULONG n=--refs;if(!n)delete this;return n;}
    HRESULT STDMETHODCALLTYPE CredentialsChanged(UINT_PTR) override{++calls;return S_OK;}
};
static bool ProviderHost(const wchar_t* path){
    // Direct loading exercises our actual COM implementation without registration,
    // credentials, LogonUI injection, lock operations or account authentication.
    HMODULE library=LoadLibraryExW(path,nullptr,LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR|LOAD_LIBRARY_SEARCH_SYSTEM32);
    CHECK(library!=nullptr);
    auto get=reinterpret_cast<HRESULT (WINAPI*)(REFCLSID,REFIID,void**)>(GetProcAddress(library,"DllGetClassObject"));
    auto unload=reinterpret_cast<HRESULT (WINAPI*)()>(GetProcAddress(library,"DllCanUnloadNow"));
    CHECK(get && unload);CHECK(unload()==S_OK);
    IClassFactory* factory=nullptr;CHECK(SUCCEEDED(get(kProviderClsid,IID_IClassFactory,reinterpret_cast<void**>(&factory))));
    CHECK(unload()==S_FALSE);
    ICredentialProvider* provider=nullptr;CHECK(SUCCEEDED(factory->CreateInstance(nullptr,IID_ICredentialProvider,reinterpret_cast<void**>(&provider))));
    CHECK(provider->SetUsageScenario(CPUS_CREDUI,0)==E_NOTIMPL);
    CHECK(provider->SetUsageScenario(CPUS_CHANGE_PASSWORD,0)==E_NOTIMPL);
    CHECK(provider->SetUsageScenario(CPUS_PLAP,0)==E_NOTIMPL);
    CHECK(provider->SetUsageScenario(CPUS_LOGON,0)==E_NOTIMPL);
    CHECK(provider->SetUsageScenario(CPUS_UNLOCK_WORKSTATION,0)==E_NOTIMPL);
    DWORD count=99,preferred=0;BOOL automatic=TRUE;
    CHECK(SUCCEEDED(provider->GetCredentialCount(&count,&preferred,&automatic)));
    CHECK(count==0 && preferred==CREDENTIAL_PROVIDER_NO_DEFAULT && !automatic);
    ICredentialProviderSetUserArray* users=nullptr;
    CHECK(SUCCEEDED(provider->QueryInterface(IID_ICredentialProviderSetUserArray,reinterpret_cast<void**>(&users))));
    CHECK(users->SetUserArray(nullptr)==E_INVALIDARG);users->Release();
    Events* events=new Events();CHECK(SUCCEEDED(provider->Advise(events,42)));CHECK(SUCCEEDED(provider->UnAdvise()));
    CHECK(events->calls==0);events->Release();provider->Release();factory->Release();
    CHECK(unload()==S_OK);CHECK(FreeLibrary(library));return true;
}
static bool SessionGates(){
    CHECK(!ConsoleTarget(L"S-1-5-21-0-0-0-999999",WTSGetActiveConsoleSessionId(),true));
    CHECK(!ConsoleTarget(CurrentSid().c_str(),0xffffffff,true));
    CHECK(!ConsoleTargetForInitialization(L"S-1-5-21-0-0-0-999999",WTSGetActiveConsoleSessionId()));
    CHECK(!ConsoleTargetForInitialization(CurrentSid().c_str(),0xffffffff));
    SystemEnrollment none{};CHECK(!ReadSystem(none));
    std::wstring username,domain,sid;DWORD session=0;
    if(ConsoleAccount(username,domain,sid,session)){
        CHECK(sid==CurrentSid());
        CHECK(ConsoleTargetForInitialization(sid.c_str(),session));
        CHECK(ConsoleTarget(sid.c_str(),session,false) || ConsoleTarget(sid.c_str(),session,true));
        printf("Local console state verified (session %lu); no credentials submitted.\n",session);
    }
    return true;
}
int wmain(int argc,wchar_t** argv){
    if(argc!=2 || IsSystem()){fprintf(stderr,"Run tests as an ordinary/elevated local user and provide DLL path.\n");return 2;}
    CoInitializeEx(nullptr,COINIT_APARTMENTTHREADED);
    bool ok=CryptoAndStorage() && Serialization() && EmptySerialization() && VerificationGates() && SessionGates() && ProviderHost(argv[1]) && ProviderHost(argv[1]);
    CoUninitialize();printf("Native checks: %u; %s. No registration/enrollment/lock performed.\n",checks,ok?"PASS":"FAIL");return ok?0:1;
}
