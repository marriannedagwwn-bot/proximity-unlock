// Minimal V2 provider. It never filters, wraps or disables another provider.
#include "common.h"
#include <atomic>
#include <thread>
#include <mutex>
#include <new>

using namespace proximity;
static std::atomic<long> gObjects{0};

class Provider;
class Credential final : public ICredentialProviderCredential2 {
    std::atomic<ULONG> refs{1}; Provider* owner;
    std::mutex proofMutex;
    VerificationSubmission proof;
public:
    explicit Credential(Provider* p);
    ~Credential();
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid,void** out) override;
    ULONG STDMETHODCALLTYPE AddRef() override { return ++refs; }
    ULONG STDMETHODCALLTYPE Release() override { ULONG n=--refs;if(!n)delete this;return n; }
    HRESULT STDMETHODCALLTYPE Advise(ICredentialProviderCredentialEvents*) override { return S_OK; }
    HRESULT STDMETHODCALLTYPE UnAdvise() override { return S_OK; }
    HRESULT STDMETHODCALLTYPE SetSelected(BOOL* automatic) override;
    HRESULT STDMETHODCALLTYPE SetDeselected() override { return S_OK; }
    HRESULT STDMETHODCALLTYPE GetFieldState(DWORD id,CREDENTIAL_PROVIDER_FIELD_STATE* state,CREDENTIAL_PROVIDER_FIELD_INTERACTIVE_STATE* interactive) override {
        if(id>1)return E_INVALIDARG; *state=CPFS_DISPLAY_IN_BOTH;*interactive=CPFIS_NONE;return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetStringValue(DWORD id,PWSTR* text) override {
        if(id>1)return E_INVALIDARG;
        const wchar_t* value=id?L"Continue":L"iPhone proximity unlock";
        *text=static_cast<PWSTR>(CoTaskMemAlloc((wcslen(value)+1)*2)); if(!*text)return E_OUTOFMEMORY;
        wcscpy_s(*text,wcslen(value)+1,value);return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetBitmapValue(DWORD,HBITMAP*) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE GetCheckboxValue(DWORD,BOOL*,PWSTR*) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE GetSubmitButtonValue(DWORD id,DWORD* adjacent) override { if(id!=1)return E_INVALIDARG;*adjacent=0;return S_OK; }
    HRESULT STDMETHODCALLTYPE GetComboBoxValueCount(DWORD,DWORD*,DWORD*) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE GetComboBoxValueAt(DWORD,DWORD,PWSTR*) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE SetStringValue(DWORD,PCWSTR) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE SetCheckboxValue(DWORD,BOOL) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE SetComboBoxSelectedValue(DWORD,DWORD) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE CommandLinkClicked(DWORD) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE GetSerialization(CREDENTIAL_PROVIDER_GET_SERIALIZATION_RESPONSE*,CREDENTIAL_PROVIDER_CREDENTIAL_SERIALIZATION*,PWSTR*,CREDENTIAL_PROVIDER_STATUS_ICON*) override;
    HRESULT STDMETHODCALLTYPE ReportResult(NTSTATUS,NTSTATUS,PWSTR* text,CREDENTIAL_PROVIDER_STATUS_ICON* icon) override;
    HRESULT STDMETHODCALLTYPE GetUserSid(PWSTR* sid) override;
};

class Provider final : public ICredentialProvider, public ICredentialProviderSetUserArray {
    std::atomic<ULONG> refs{1}; std::atomic<bool> stop{false};
    std::thread worker; std::mutex mutex;
    ICredentialProviderEvents* events=nullptr; UINT_PTR eventContext=0;
    bool pending=false,attempted=false,userMatched=false;
    ULONGLONG pendingUntil=0;
    DWORD session=0; std::wstring sid;
    CREDENTIAL_PROVIDER_USAGE_SCENARIO scenario=CPUS_INVALID;
    std::atomic<HWND> notifyWindow{nullptr};
    std::wstring windowClass;
    HMODULE windowModule=nullptr;
    static LRESULT CALLBACK WindowProc(HWND hwnd,UINT message,WPARAM wp,LPARAM lp) {
        Provider* self=reinterpret_cast<Provider*>(GetWindowLongPtrW(hwnd,GWLP_USERDATA));
        if(message==WM_NCCREATE){self=static_cast<Provider*>(reinterpret_cast<CREATESTRUCTW*>(lp)->lpCreateParams);SetWindowLongPtrW(hwnd,GWLP_USERDATA,reinterpret_cast<LONG_PTR>(self));}
        if(message==WM_APP+1 && self){self->NotifyOnMain();return 0;}
        return DefWindowProcW(hwnd,message,wp,lp);
    }
    bool Eligible() {
        return userMatched && !sid.empty() && (scenario==CPUS_LOGON || scenario==CPUS_UNLOCK_WORKSTATION) &&
            ConsoleTarget(sid.c_str(),session,true);
    }
    bool PeerMatches(HANDLE pipe) {
        if(!ImpersonateNamedPipeClient(pipe))return false;
        HANDLE raw=nullptr; bool ok=OpenThreadToken(GetCurrentThread(),TOKEN_QUERY,TRUE,&raw)!=FALSE;
        if(ok) {
            Handle token(raw); DWORD count=0;GetTokenInformation(token,TokenUser,nullptr,0,&count);
            std::vector<BYTE> bytes(count);DWORD target=0,returned=0;
            ok=GetTokenInformation(token,TokenUser,bytes.data(),count,&count) &&
                SidString(reinterpret_cast<TOKEN_USER*>(bytes.data())->User.Sid)==sid &&
                GetTokenInformation(token,TokenSessionId,&target,sizeof(target),&returned) && target==session;
        }
        RevertToSelf(); return ok;
    }
    void NotifyOnMain() {
        ICredentialProviderEvents* current=nullptr;UINT_PTR context=0;
        {std::lock_guard<std::mutex> guard(mutex);current=events;context=eventContext;if(current)current->AddRef();}
        if(current){HRESULT hr=current->CredentialsChanged(context);NativeTrace(L"NotifyResult",0,hr);current->Release();}
    }
    void Notify() { HWND hwnd=notifyWindow.load();BOOL ok=hwnd && PostMessageW(hwnd,WM_APP+1,0,0);NativeTrace(L"NotifyQueued",ok?0:GetLastError()); }
    void Serve() {
        // The provider runs inside LogonUI as SYSTEM on the session's secure desktop.
        if(!IsSystem())return;
        PSECURITY_DESCRIPTOR sd=nullptr;
        std::wstring acl=L"D:P(A;;GA;;;SY)(A;;GRGW;;;"+sid+L")";
        if(!ConvertStringSecurityDescriptorToSecurityDescriptorW(acl.c_str(),SDDL_REVISION_1,&sd,nullptr)){NativeTrace(L"PipeSecurity",GetLastError());return;}
        SECURITY_ATTRIBUTES sa{sizeof(sa),sd,FALSE};
        while(!stop) {
            Handle pipe(CreateNamedPipeW(PipeName(session).c_str(),
                PIPE_ACCESS_DUPLEX|FILE_FLAG_OVERLAPPED|FILE_FLAG_FIRST_PIPE_INSTANCE,
                PIPE_TYPE_MESSAGE|PIPE_READMODE_MESSAGE|PIPE_WAIT|PIPE_REJECT_REMOTE_CLIENTS,
                1,sizeof(Challenge),sizeof(Request),1200,&sa));
            if(!pipe){NativeTrace(L"PipeCreate",GetLastError());break;}
            NativeTrace(L"PipeReady");
            Handle event(CreateEventW(nullptr,TRUE,FALSE,nullptr));OVERLAPPED over{};over.hEvent=event;
            bool connected=ConnectNamedPipe(pipe,&over)!=FALSE;
            DWORD error=connected?ERROR_SUCCESS:GetLastError();
            if(error==ERROR_PIPE_CONNECTED)connected=true;
            else if(error==ERROR_IO_PENDING) {
                while(!stop && WaitForSingleObject(event,100)==WAIT_TIMEOUT){}
                DWORD n=0;
                if(stop){CancelIoEx(pipe,&over);GetOverlappedResult(pipe,&over,&n,TRUE);}
                else connected=GetOverlappedResult(pipe,&over,&n,FALSE)!=FALSE;
            }
            if(connected && !stop) Process(pipe);
            else if(!stop)NativeTrace(L"PipeConnect",GetLastError());
            // Do not FlushFileBuffers on a pipe: an unresponsive client can block LogonUI teardown.
            DisconnectNamedPipe(pipe);
        }
        LocalFree(sd);
    }
    void Process(HANDLE pipe) {
        {std::lock_guard<std::mutex> guard(mutex);bool eligible=Eligible();
            DWORD detail=(eligible?1:0)|(attempted?2:0)|(pending?4:0)|(events?8:0);
            bool allowed=eligible && !attempted && !pending && events;
            NativeTrace(L"ProcessEligible",allowed?0:ERROR_ACCESS_DENIED,S_OK,0,0,detail);if(!allowed)return;}
        Secret secret;
        if(!ReadSystem(secret.value) || !RegistryEnabled(secret.value.user,true) || std::wstring(secret.value.user.sid)!=sid){NativeTrace(L"ReadEnrollment",ERROR_ACCESS_DENIED);return;}
        Challenge challenge{};memcpy(challenge.magic,"PRXCHAL1",8);challenge.version=1;
        challenge.keyId=secret.value.user.keyId;challenge.session=session;challenge.expires=GetTickCount64()+2000;
        wcscpy_s(challenge.sid,sid.c_str());
        if(!Random(challenge.nonce,32) || !Hmac(secret.value.user.ipc,&challenge,offsetof(Challenge,mac),challenge.mac) ||
           !Transfer(pipe,&challenge,sizeof(challenge),true)){NativeTrace(L"ChallengeWrite",GetLastError());return;}
        Request request{};BYTE expected[32]{};
        if(!Transfer(pipe,&request,sizeof(request),false) || !PeerMatches(pipe) || memcmp(request.magic,"PRXREQ01",8) ||
           GetTickCount64()>challenge.expires){NativeTrace(L"RequestRejected",ERROR_ACCESS_DENIED,S_OK,0,0,1);return;}
        std::vector<BYTE> message(8+sizeof(challenge));memcpy(message.data(),request.magic,8);memcpy(message.data()+8,&challenge,sizeof(challenge));
        if(!Hmac(secret.value.user.ipc,message.data(),static_cast<DWORD>(message.size()),expected) || !ConstantEqual(expected,request.mac,32)){NativeTrace(L"RequestRejected",ERROR_ACCESS_DENIED,S_OK,0,0,2);return;}
        SecureZeroMemory(&secret.value,sizeof(secret.value));
        {std::lock_guard<std::mutex> guard(mutex);
            if(!Eligible() || attempted || pending || !events || GetTickCount64()>challenge.expires){NativeTrace(L"RequestRejected",ERROR_ACCESS_DENIED,S_OK,0,0,3);return;}
            pending=true;pendingUntil=GetTickCount64()+1800;
        }
        BYTE accepted=1;if(!Transfer(pipe,&accepted,1,true)) {
            NativeTrace(L"AckWrite",GetLastError());std::lock_guard<std::mutex> guard(mutex);pending=false;return;
        }
        NativeTrace(L"RequestAccepted");
        Notify();
    }
public:
    Provider(){++gObjects;}
    ~Provider(){UnAdvise();--gObjects;}
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid,void** out) override {
        if(!out)return E_POINTER;*out=nullptr;
        if(iid==IID_IUnknown || iid==IID_ICredentialProvider)*out=static_cast<ICredentialProvider*>(this);
        else if(iid==IID_ICredentialProviderSetUserArray)*out=static_cast<ICredentialProviderSetUserArray*>(this);
        else return E_NOINTERFACE;AddRef();return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef() override{return ++refs;}
    ULONG STDMETHODCALLTYPE Release() override{ULONG n=--refs;if(!n)delete this;return n;}
    HRESULT STDMETHODCALLTYPE SetUsageScenario(CREDENTIAL_PROVIDER_USAGE_SCENARIO value,DWORD flags) override {
        NativeTrace(L"UsageScenario",0,S_FALSE,0,0,value);
        if((value!=CPUS_LOGON && value!=CPUS_UNLOCK_WORKSTATION) || flags){NativeTrace(L"UsageRejected",0,E_NOTIMPL,0,0,1);return E_NOTIMPL;}
        DWORD processSession=0;
        if(!IsSystem() || !ProcessIdToSessionId(GetCurrentProcessId(),&processSession)){NativeTrace(L"UsageRejected",ERROR_ACCESS_DENIED,E_NOTIMPL,0,0,2);return E_NOTIMPL;}
        Secret secret;if(!ReadSystem(secret.value) || !RegistryEnabled(secret.value.user,true) ||
            !ConsoleTargetForInitialization(secret.value.user.sid,processSession)){NativeTrace(L"UsageRejected",ERROR_ACCESS_DENIED,E_NOTIMPL,0,0,3);return E_NOTIMPL;}
        sid=secret.value.user.sid;session=processSession;scenario=value;
        NativeTrace(L"UsageScenario",0,S_OK,0,0,value);return S_OK;
    }
    HRESULT STDMETHODCALLTYPE SetSerialization(const CREDENTIAL_PROVIDER_CREDENTIAL_SERIALIZATION*) override{return E_NOTIMPL;}
    HRESULT STDMETHODCALLTYPE Advise(ICredentialProviderEvents* value,UINT_PTR context) override {
        if(!value)return E_INVALIDARG;
        if(!notifyWindow.load()){
            GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS|GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                reinterpret_cast<LPCWSTR>(&WindowProc),&windowModule);
            windowClass=L"ProximityUnlockNotifications-"+std::to_wstring(reinterpret_cast<uintptr_t>(this));
            WNDCLASSW wc{};wc.lpfnWndProc=WindowProc;wc.hInstance=windowModule;wc.lpszClassName=windowClass.c_str();
            if(!RegisterClassW(&wc)){DWORD error=GetLastError();NativeTrace(L"Advise",error,HRESULT_FROM_WIN32(error));return HRESULT_FROM_WIN32(error);}
            HWND hwnd=CreateWindowExW(0,wc.lpszClassName,L"",0,0,0,0,0,HWND_MESSAGE,nullptr,windowModule,this);
            if(!hwnd){DWORD error=GetLastError();UnregisterClassW(windowClass.c_str(),windowModule);windowClass.clear();NativeTrace(L"Advise",error,HRESULT_FROM_WIN32(error));return HRESULT_FROM_WIN32(error);}notifyWindow=hwnd;
        }
        {std::lock_guard<std::mutex> guard(mutex);if(events)events->Release();events=value;events->AddRef();eventContext=context;}
        if(!worker.joinable() && !sid.empty()){stop=false;worker=std::thread([this]{Serve();});}NativeTrace(L"Advise");return S_OK;
    }
    HRESULT STDMETHODCALLTYPE UnAdvise() override {
        HWND hwnd=notifyWindow.exchange(nullptr);if(hwnd)DestroyWindow(hwnd);
        if(!windowClass.empty()){UnregisterClassW(windowClass.c_str(),windowModule);windowClass.clear();}
        stop=true;if(worker.joinable())worker.join();
        std::lock_guard<std::mutex> guard(mutex);pending=false;if(events){events->Release();events=nullptr;}return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetFieldDescriptorCount(DWORD* count) override{*count=2;return S_OK;}
    HRESULT STDMETHODCALLTYPE GetFieldDescriptorAt(DWORD id,CREDENTIAL_PROVIDER_FIELD_DESCRIPTOR** out) override {
        if(id>1)return E_INVALIDARG;*out=static_cast<CREDENTIAL_PROVIDER_FIELD_DESCRIPTOR*>(CoTaskMemAlloc(sizeof(**out)));
        if(!*out)return E_OUTOFMEMORY;ZeroMemory(*out,sizeof(**out));(*out)->dwFieldID=id;
        (*out)->cpft=id?CPFT_SUBMIT_BUTTON:CPFT_LARGE_TEXT;return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetCredentialCount(DWORD* count,DWORD* preferred,BOOL* automatic) override {
        std::lock_guard<std::mutex> guard(mutex);
        bool ready=Eligible() && pending && !attempted && GetTickCount64()<=pendingUntil;
        NativeTrace(L"CountReady",0,S_OK,0,0,ready?1:0);
        *count=ready?1:0;*preferred=ready?0:CREDENTIAL_PROVIDER_NO_DEFAULT;*automatic=ready;return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetCredentialAt(DWORD index,ICredentialProviderCredential** out) override {
        if(index || sid.empty())return E_INVALIDARG;
        *out=new(std::nothrow)Credential(this);return *out?S_OK:E_OUTOFMEMORY;
    }
    HRESULT STDMETHODCALLTYPE SetUserArray(ICredentialProviderUserArray* users) override {
        std::lock_guard<std::mutex> guard(mutex);userMatched=false;
        DWORD count=0;if(!users || FAILED(users->GetCount(&count))){NativeTrace(L"UserArrayMatched",ERROR_INVALID_PARAMETER,E_INVALIDARG);return E_INVALIDARG;}
        for(DWORD i=0;i<count;++i){
            ICredentialProviderUser* user=nullptr;PWSTR found=nullptr;
            if(SUCCEEDED(users->GetAt(i,&user))){if(SUCCEEDED(user->GetSid(&found))){if(found && sid==found)userMatched=true;CoTaskMemFree(found);}user->Release();}
        }NativeTrace(L"UserArrayMatched",0,S_OK,0,0,userMatched?1:0);return S_OK;
    }
    bool Ready(){std::lock_guard<std::mutex> guard(mutex);return pending && !attempted && GetTickCount64()<=pendingUntil && Eligible();}
    std::wstring TargetSid(){return sid;}
    HRESULT Consume(CREDENTIAL_PROVIDER_GET_SERIALIZATION_RESPONSE* response,CREDENTIAL_PROVIDER_CREDENTIAL_SERIALIZATION* result,
                    DWORD& submittedKeyId,bool& provisionalSubmission) {
        submittedKeyId=0;provisionalSubmission=false;
        *response=CPGSR_NO_CREDENTIAL_NOT_FINISHED;ZeroMemory(result,sizeof(*result));
        {
            std::lock_guard<std::mutex> guard(mutex);
            if(!pending || attempted || GetTickCount64()>pendingUntil || !Eligible()){pending=false;NativeTrace(L"SerializationGate",ERROR_ACCESS_DENIED,S_FALSE);return S_OK;}
            // Consume before touching the password. Even an auth failure cannot resubmit this request.
            pending=false;attempted=true;
        }
        Secret secret;if(!ReadSystem(secret.value) || !RegistryEnabled(secret.value.user,true) ||
            std::wstring(secret.value.user.sid)!=sid || !ConsoleTarget(sid.c_str(),session,true)){NativeTrace(L"SerializationGate",ERROR_ACCESS_DENIED,S_FALSE);return S_OK;}
        bool provisional=!RegistryEnabled(secret.value.user);
        if(provisional && secret.value.password[0]){NativeTrace(L"SerializationGate",ERROR_ACCESS_DENIED,S_FALSE);return S_OK;}
        HRESULT hr=Serialize(secret.value,scenario,result);
        NativeTrace(L"Serialize",0,hr,0,0,provisional?1:0);
        if(SUCCEEDED(hr)){
            submittedKeyId=secret.value.user.keyId;provisionalSubmission=provisional;
            *response=CPGSR_RETURN_CREDENTIAL_FINISHED;
        }return hr;
    }
    void AuthenticationResult(DWORD key,NTSTATUS status,NTSTATUS substatus){
        if(!key)return;
        // Only Winlogon's actual authentication result can verify a provisional
        // empty credential; a standalone 1327 or manual unlock never does this.
        bool marked=MarkConsoleVerified(key,sid,session,status,substatus);
        NativeTrace(L"MarkVerified",marked?0:ERROR_ACCESS_DENIED,marked?S_OK:S_FALSE,status,substatus,marked?1:0);
    }
};

Credential::Credential(Provider* p):owner(p){owner->AddRef();++gObjects;}
Credential::~Credential(){owner->Release();--gObjects;}
HRESULT Credential::QueryInterface(REFIID iid,void** out){
    if(!out)return E_POINTER;*out=nullptr;
    if(iid==IID_IUnknown || iid==IID_ICredentialProviderCredential || iid==IID_ICredentialProviderCredential2)*out=static_cast<ICredentialProviderCredential2*>(this);
    else return E_NOINTERFACE;AddRef();return S_OK;
}
HRESULT Credential::SetSelected(BOOL* automatic){*automatic=owner->Ready();return S_OK;}
HRESULT Credential::GetSerialization(CREDENTIAL_PROVIDER_GET_SERIALIZATION_RESPONSE* response,CREDENTIAL_PROVIDER_CREDENTIAL_SERIALIZATION* result,PWSTR* text,CREDENTIAL_PROVIDER_STATUS_ICON* icon){
    std::lock_guard<std::mutex> guard(proofMutex);
    DWORD key=0;bool provisional=false;
    *text=nullptr;*icon=CPSI_NONE;
    HRESULT hr=owner->Consume(response,result,key,provisional);
    proof.Serialized(key,SUCCEEDED(hr) && *response==CPGSR_RETURN_CREDENTIAL_FINISHED && provisional);
    return hr;
}
HRESULT Credential::ReportResult(NTSTATUS status,NTSTATUS substatus,PWSTR* text,CREDENTIAL_PROVIDER_STATUS_ICON* icon){
    DWORD key=0;{std::lock_guard<std::mutex> guard(proofMutex);key=proof.Consume();}
    NativeTrace(L"ReportResult",0,S_OK,status,substatus,key?1:0);
    *text=nullptr;*icon=CPSI_NONE;owner->AuthenticationResult(key,status,substatus);return S_OK;
}
HRESULT Credential::GetUserSid(PWSTR* result){
    auto sid=owner->TargetSid();*result=static_cast<PWSTR>(CoTaskMemAlloc((sid.size()+1)*2));
    if(!*result)return E_OUTOFMEMORY;wcscpy_s(*result,sid.size()+1,sid.c_str());return S_OK;
}
class Factory final : public IClassFactory {
    std::atomic<ULONG> refs{1};
public:
    Factory(){++gObjects;}~Factory(){--gObjects;}
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid,void** out) override {
        if(!out)return E_POINTER;*out=nullptr;if(iid!=IID_IUnknown && iid!=IID_IClassFactory)return E_NOINTERFACE;
        *out=static_cast<IClassFactory*>(this);AddRef();return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef() override{return ++refs;}
    ULONG STDMETHODCALLTYPE Release() override{ULONG n=--refs;if(!n)delete this;return n;}
    HRESULT STDMETHODCALLTYPE CreateInstance(IUnknown* outer,REFIID iid,void** out) override {
        if(outer)return CLASS_E_NOAGGREGATION;
        auto p=new(std::nothrow)Provider();if(!p)return E_OUTOFMEMORY;HRESULT hr=p->QueryInterface(iid,out);p->Release();return hr;
    }
    HRESULT STDMETHODCALLTYPE LockServer(BOOL lock) override{gObjects+=lock?1:-1;return S_OK;}
};
extern "C" __declspec(dllexport) HRESULT WINAPI DllGetClassObject(REFCLSID clsid,REFIID iid,void** out){
    if(clsid!=kProviderClsid)return CLASS_E_CLASSNOTAVAILABLE;
    auto factory=new(std::nothrow)Factory();if(!factory)return E_OUTOFMEMORY;HRESULT hr=factory->QueryInterface(iid,out);factory->Release();return hr;
}
extern "C" __declspec(dllexport) HRESULT WINAPI DllCanUnloadNow(){return gObjects==0?S_OK:S_FALSE;}
BOOL WINAPI DllMain(HINSTANCE instance,DWORD reason,LPVOID){if(reason==DLL_PROCESS_ATTACH)DisableThreadLibraryCalls(instance);return TRUE;}
