#include "common.h"
#include "qrcodegen.hpp"
#include <algorithm>
#include <cstdio>

using namespace proximity;
static DWORD enrollmentError=0;
static void Error(const wchar_t* text){MessageBoxW(nullptr,text,L"Proximity Unlock",MB_OK|MB_ICONERROR);}
struct SetupState {
    bool administrator=false,tokenQuery=false,elevated=false,accountResolved=false,processSessionResolved=false;
    bool sessionMatches=false,sidMatches=false,unlocked=false,locked=false,wtsQuery=false,protocolQuery=false;
    bool inputDesktopOpen=false,inputDesktopDefault=false;
    DWORD processSession=0xffffffff,consoleSession=0xffffffff,wtsSession=0xffffffff,wtsLevel=0,waitedMs=0;
    DWORD wtsError=0,protocolError=0,desktopError=0,elevationType=0;
    LONG wtsState=-1,wtsFlags=-1;
    USHORT protocol=0xffff;
    bool BaseReady() const {return administrator && accountResolved && processSessionResolved && sessionMatches && sidMatches;}
    bool Ready() const {return BaseReady() && unlocked;}
};
static SetupState lastSetup;
static SetupState InspectSetup(std::wstring& username,std::wstring& domain,std::wstring& sid,DWORD& session){
    SetupState result;result.administrator=IsAdministrator();
    HANDLE raw=nullptr;
    if(OpenProcessToken(GetCurrentProcess(),TOKEN_QUERY,&raw)){
        Handle token(raw);TOKEN_ELEVATION elevation{};DWORD size=0;
        result.tokenQuery=GetTokenInformation(token,TokenElevation,&elevation,sizeof(elevation),&size)!=FALSE;
        result.elevated=result.tokenQuery && elevation.TokenIsElevated;
        TOKEN_ELEVATION_TYPE type=TokenElevationTypeDefault;
        if(GetTokenInformation(token,TokenElevationType,&type,sizeof(type),&size))result.elevationType=type;
    }
    result.consoleSession=WTSGetActiveConsoleSessionId();
    result.processSessionResolved=ProcessIdToSessionId(GetCurrentProcessId(),&result.processSession)!=FALSE;
    result.accountResolved=ConsoleAccount(username,domain,sid,session);
    result.sessionMatches=result.processSessionResolved && result.processSession==result.consoleSession && result.accountResolved && session==result.consoleSession;
    auto current=CurrentSid();result.sidMatches=result.accountResolved && !current.empty() && current==sid;
    if(result.accountResolved){
        result.unlocked=ConsoleTarget(sid.c_str(),session,false);
        result.locked=ConsoleTarget(sid.c_str(),session,true);
    }
    LPWSTR text=nullptr;DWORD bytes=0;
    if(WTSQuerySessionInformationW(WTS_CURRENT_SERVER_HANDLE,result.consoleSession,WTSSessionInfoEx,&text,&bytes)){
        if(bytes>=sizeof(WTSINFOEXW)){
            auto info=reinterpret_cast<WTSINFOEXW*>(text);result.wtsLevel=info->Level;
            if(info->Level==1){result.wtsQuery=true;result.wtsSession=info->Data.WTSInfoExLevel1.SessionId;
                result.wtsState=info->Data.WTSInfoExLevel1.SessionState;result.wtsFlags=info->Data.WTSInfoExLevel1.SessionFlags;}
        }WTSFreeMemory(text);
    }else result.wtsError=GetLastError();
    text=nullptr;bytes=0;
    if(WTSQuerySessionInformationW(WTS_CURRENT_SERVER_HANDLE,result.consoleSession,WTSClientProtocolType,&text,&bytes)){
        result.protocolQuery=bytes>=sizeof(USHORT);if(result.protocolQuery)result.protocol=*reinterpret_cast<USHORT*>(text);WTSFreeMemory(text);
    }else result.protocolError=GetLastError();
    HDESK desktop=OpenInputDesktop(0,FALSE,DESKTOP_READOBJECTS);
    if(desktop){
        result.inputDesktopOpen=true;wchar_t name[64]{};DWORD count=0;
        if(GetUserObjectInformationW(desktop,UOI_NAME,name,sizeof(name),&count))result.inputDesktopDefault=_wcsicmp(name,L"Default")==0;
        CloseDesktop(desktop);
    }else result.desktopError=GetLastError();
    return result;
}
static void PrintSetup(const SetupState& state){
    auto boolean=[](bool value){return value?"true":"false";};
    printf("{\"setupStatus\":true,\"eligible\":%s,\"administrator\":%s,\"tokenQuery\":%s,\"elevated\":%s,\"elevationType\":%lu,\"accountResolved\":%s,\"processSessionResolved\":%s,\"processSession\":%lu,\"consoleSession\":%lu,\"sessionMatches\":%s,\"sidMatches\":%s,\"unlocked\":%s,\"locked\":%s,\"wtsQuery\":%s,\"wtsLevel\":%lu,\"wtsSession\":%lu,\"wtsState\":%ld,\"wtsFlags\":%ld,\"wtsError\":%lu,\"protocolQuery\":%s,\"protocol\":%u,\"protocolError\":%lu,\"inputDesktopOpen\":%s,\"inputDesktopDefault\":%s,\"desktopError\":%lu,\"waitedMs\":%lu}\n",
        boolean(state.Ready()),boolean(state.administrator),boolean(state.tokenQuery),boolean(state.elevated),state.elevationType,
        boolean(state.accountResolved),boolean(state.processSessionResolved),state.processSession,state.consoleSession,
        boolean(state.sessionMatches),boolean(state.sidMatches),boolean(state.unlocked),boolean(state.locked),boolean(state.wtsQuery),
        state.wtsLevel,state.wtsSession,state.wtsState,state.wtsFlags,state.wtsError,boolean(state.protocolQuery),state.protocol,
        state.protocolError,boolean(state.inputDesktopOpen),boolean(state.inputDesktopDefault),state.desktopError,state.waitedMs);
    fflush(stdout);
}
static std::wstring SetupFailureText(){
    auto b=[](bool value){return value?L"true":L"false";};
    return L"Run enrollment elevated as the currently UNLOCKED local console account. Microsoft/domain accounts and RDP are not supported.\n\n"
        L"administrator="+std::wstring(b(lastSetup.administrator))+L", elevated="+b(lastSetup.elevated)+L", elevationType="+std::to_wstring(lastSetup.elevationType)+
        L"\naccountResolved="+b(lastSetup.accountResolved)+L", SID matches="+b(lastSetup.sidMatches)+
        L"\nprocess session="+std::to_wstring(lastSetup.processSession)+L", console session="+std::to_wstring(lastSetup.consoleSession)+L", session matches="+b(lastSetup.sessionMatches)+
        L"\nunlocked="+b(lastSetup.unlocked)+L", locked="+b(lastSetup.locked)+L", WTS query="+b(lastSetup.wtsQuery)+
        L"\nWTS session="+std::to_wstring(lastSetup.wtsSession)+L", state="+std::to_wstring(lastSetup.wtsState)+L", flags="+std::to_wstring(lastSetup.wtsFlags)+L", error="+std::to_wstring(lastSetup.wtsError)+
        L"\nprotocol="+std::to_wstring(lastSetup.protocol)+L", default input desktop="+b(lastSetup.inputDesktopDefault)+L", waited ms="+std::to_wstring(lastSetup.waitedMs)+
        L"\n\nNo credential authentication or enrollment was attempted. Use setup-status for the same read-only diagnostics.";
}
static bool ConsoleSetup(std::wstring& username,std::wstring& domain,std::wstring& sid,DWORD& session){
    ULONGLONG start=GetTickCount64();
    lastSetup=InspectSetup(username,domain,sid,session);
    // UAC may briefly leave WTS reporting a locked console after consent closes.
    // Wait only when every identity/admin gate already passes, then recheck all
    // gates. This never treats a timeout, unknown state or locked state as ready.
    while(lastSetup.BaseReady() && !lastSetup.unlocked && GetTickCount64()-start<5000){
        Sleep(100);lastSetup=InspectSetup(username,domain,sid,session);
    }
    lastSetup.waitedMs=static_cast<DWORD>(GetTickCount64()-start);
    if(!lastSetup.Ready())PrintSetup(lastSetup);
    return lastSetup.Ready();
}
static bool SetReg(const wchar_t* name,DWORD type,const void* value,DWORD size){
    HKEY key=nullptr;if(RegCreateKeyExW(HKEY_LOCAL_MACHINE,kRegistry,0,nullptr,0,KEY_SET_VALUE|KEY_WOW64_64KEY,nullptr,&key,nullptr))return false;
    bool ok=RegSetValueExW(key,name,0,type,static_cast<const BYTE*>(value),size)==ERROR_SUCCESS;RegCloseKey(key);return ok;
}
// The phone scans the same JSON as a QR code (ECC M, 4-module white border). Drawn in memory only:
// never saved to a file or the clipboard. The module copy is zeroed when the window closes.
constexpr int kQrBorder=4,kQrBox=294,kQrTop=70,kClientWidth=672;
// win_peer.py sets this after a valid iPhone enrollment acknowledgement (docs/protocol.md); the window then
// clears the QR/JSON, shows a status line and closes. Without it the window just stays until closed by hand.
constexpr wchar_t kEnrollAckEvent[]=L"Local\\iphone-proximity-unlock-enroll-ack";
constexpr UINT_PTR kAckPollTimer=1,kAckCloseTimer=2;
struct KeyView {const wchar_t* json=nullptr;std::vector<unsigned char> modules;int size=0;HANDLE ack=nullptr;};
// Medium label and interactive-user write access: Enroll runs this helper elevated, the BLE peer does not.
constexpr wchar_t kAckEventSddl[]=L"D:(A;;0x1F0003;;;SY)(A;;0x1F0003;;;BA)(A;;0x1F0003;;;IU)S:(ML;;NW;;;ME)";
static HANDLE CreateAckEvent(){
    PSECURITY_DESCRIPTOR sd=nullptr;SECURITY_ATTRIBUTES sa{sizeof(sa),nullptr,FALSE};
    if(ConvertStringSecurityDescriptorToSecurityDescriptorW(kAckEventSddl,SDDL_REVISION_1,&sd,nullptr))sa.lpSecurityDescriptor=sd;
    HANDLE event=CreateEventW(sd?&sa:nullptr,TRUE,FALSE,kEnrollAckEvent);
    if(sd)LocalFree(sd);
    if(event)ResetEvent(event);  // A signal left over from an earlier window does not count.
    return event;
}
static bool EncodeQr(const std::wstring& json,KeyView& view){
    std::string text(json.size(),'\0');
    for(size_t i=0;i<json.size();i++){if(json[i]>0x7f)return false;text[i]=static_cast<char>(json[i]);}
    try{
        auto qr=qrcodegen::QrCode::encodeText(text.c_str(),qrcodegen::QrCode::Ecc::MEDIUM);
        view.size=qr.getSize();view.modules.assign(static_cast<size_t>(view.size)*view.size,0);
        for(int y=0;y<view.size;y++)for(int x=0;x<view.size;x++)view.modules[static_cast<size_t>(y)*view.size+x]=qr.getModule(x,y)?1:0;
    }catch(...){view.size=0;view.modules.clear();}
    SecureZeroMemory(text.data(),text.size());return view.size>0;
}
static void ClearQr(KeyView& view){if(!view.modules.empty())SecureZeroMemory(view.modules.data(),view.modules.size());view.modules.clear();view.size=0;}
static void PaintQr(HWND hwnd,HDC dc){
    auto view=reinterpret_cast<KeyView*>(GetWindowLongPtrW(hwnd,GWLP_USERDATA));
    if(!view || !view->size)return;
    int cells=view->size+2*kQrBorder,cell=std::max(1,kQrBox/cells),side=cells*cell;
    int left=(kClientWidth-side)/2,top=kQrTop+(kQrBox-side)/2;
    RECT box{left,top,left+side,top+side};FillRect(dc,&box,static_cast<HBRUSH>(GetStockObject(WHITE_BRUSH)));
    auto black=static_cast<HBRUSH>(GetStockObject(BLACK_BRUSH));
    for(int y=0;y<view->size;y++)for(int x=0;x<view->size;x++){
        if(!view->modules[static_cast<size_t>(y)*view->size+x])continue;
        RECT m{left+(x+kQrBorder)*cell,top+(y+kQrBorder)*cell,left+(x+kQrBorder+1)*cell,top+(y+kQrBorder+1)*cell};FillRect(dc,&m,black);
    }
}
static LRESULT CALLBACK KeyWindow(HWND hwnd,UINT message,WPARAM wp,LPARAM lp){
    if(message==WM_CREATE){
        auto view=static_cast<KeyView*>(reinterpret_cast<CREATESTRUCTW*>(lp)->lpCreateParams);
        SetWindowLongPtrW(hwnd,GWLP_USERDATA,reinterpret_cast<LONG_PTR>(view));
        int editTop=kQrTop+kQrBox+12;
        // 扫码登记 is the iPhone app's "scan to enroll" button; escaped so MSVC reads it without /utf-8.
        auto label=CreateWindowExW(0,L"STATIC",L"Scan this QR code in the iPhone app (computer details > 扫码登记), or paste the JSON below.\nIt is a random key, not your password. No plaintext file is saved; if you copy the JSON, clear your clipboard afterwards.",WS_CHILD|WS_VISIBLE,16,14,640,50,hwnd,reinterpret_cast<HMENU>(100),nullptr,nullptr);
        auto edit=CreateWindowExW(WS_EX_CLIENTEDGE,L"EDIT",view->json,WS_CHILD|WS_VISIBLE|WS_TABSTOP|ES_MULTILINE|ES_READONLY|ES_AUTOVSCROLL,16,editTop,640,64,hwnd,reinterpret_cast<HMENU>(101),nullptr,nullptr);
        SendMessageW(label,WM_SETFONT,reinterpret_cast<WPARAM>(GetStockObject(DEFAULT_GUI_FONT)),TRUE);
        SendMessageW(edit,WM_SETFONT,reinterpret_cast<WPARAM>(GetStockObject(ANSI_FIXED_FONT)),TRUE);
        CreateWindowExW(0,L"BUTTON",L"Close",WS_CHILD|WS_VISIBLE|WS_TABSTOP|BS_DEFPUSHBUTTON,556,editTop+64+14,100,30,hwnd,reinterpret_cast<HMENU>(IDOK),nullptr,nullptr);
        if(view->ack)SetTimer(hwnd,kAckPollTimer,250,nullptr);
        SetFocus(edit);return 0;
    }
    if(message==WM_PAINT){PAINTSTRUCT ps{};HDC dc=BeginPaint(hwnd,&ps);PaintQr(hwnd,dc);EndPaint(hwnd,&ps);return 0;}
    if(message==WM_TIMER){
        auto view=reinterpret_cast<KeyView*>(GetWindowLongPtrW(hwnd,GWLP_USERDATA));
        if(wp==kAckPollTimer && view && view->ack && WaitForSingleObject(view->ack,0)==WAIT_OBJECT_0){
            KillTimer(hwnd,kAckPollTimer);ClearQr(*view);SetWindowTextW(GetDlgItem(hwnd,101),L"");
            // "已收到 iPhone 确认，即将关闭。" = received the iPhone confirmation, closing.
            SetWindowTextW(GetDlgItem(hwnd,100),L"已收到 iPhone 确认，即将关闭。\nThe iPhone confirmed it saved this key. This window closes in 2 seconds.");
            InvalidateRect(hwnd,nullptr,TRUE);SetTimer(hwnd,kAckCloseTimer,2000,nullptr);
        }else if(wp==kAckCloseTimer){KillTimer(hwnd,kAckCloseTimer);SendMessageW(hwnd,WM_CLOSE,0,0);}
        return 0;
    }
    if(message==WM_COMMAND && LOWORD(wp)==IDOK){SendMessageW(hwnd,WM_CLOSE,0,0);return 0;}
    if(message==WM_CLOSE){
        SetWindowTextW(GetDlgItem(hwnd,101),L"");
        if(auto view=reinterpret_cast<KeyView*>(GetWindowLongPtrW(hwnd,GWLP_USERDATA)))ClearQr(*view);
        DestroyWindow(hwnd);return 0;
    }
    if(message==WM_DESTROY){KillTimer(hwnd,kAckPollTimer);KillTimer(hwnd,kAckCloseTimer);PostQuitMessage(0);return 0;}
    return DefWindowProcW(hwnd,message,wp,lp);
}
static bool Export(){
    UserEnrollment user{};std::wstring username,domain,sid;DWORD session=0;
    if(!ReadUser(user) || !RegistryEnabled(user) || !ConsoleAccount(username,domain,sid,session) || sid!=CurrentSid() || !ConsoleTarget(sid.c_str(),session,false))return false;
    char base64[64]{};DWORD count=sizeof(base64);bool ok=false;
    if(CryptBinaryToStringA(user.phone,32,CRYPT_STRING_BASE64|CRYPT_STRING_NOCRLF,base64,&count)){
        std::string encoded(base64);std::wstring json=L"{\"version\":1,\"keyID\":"+std::to_wstring(user.keyId)+L",\"secret\":\""+std::wstring(encoded.begin(),encoded.end())+L"\"}";
        KeyView view;view.json=json.c_str();EncodeQr(json,view);  // Without a QR the JSON is still shown for pasting.
        view.ack=CreateAckEvent();
        WNDCLASSW wc{};wc.lpfnWndProc=KeyWindow;wc.hInstance=GetModuleHandleW(nullptr);wc.lpszClassName=L"ProximityUnlockLocalKey";wc.hCursor=LoadCursorW(nullptr,IDC_ARROW);
        wc.hbrBackground=reinterpret_cast<HBRUSH>(COLOR_BTNFACE+1);
        if(RegisterClassW(&wc)){
            RECT frame{0,0,kClientWidth,kQrTop+kQrBox+12+64+14+30+16};
            AdjustWindowRectEx(&frame,WS_CAPTION|WS_SYSMENU,FALSE,WS_EX_DLGMODALFRAME);
            HWND hwnd=CreateWindowExW(WS_EX_DLGMODALFRAME,wc.lpszClassName,L"iPhone offline enrollment",WS_CAPTION|WS_SYSMENU|WS_VISIBLE,CW_USEDEFAULT,CW_USEDEFAULT,frame.right-frame.left,frame.bottom-frame.top,nullptr,nullptr,wc.hInstance,&view);
            if(hwnd){MSG message{};while(GetMessageW(&message,nullptr,0,0)>0){if(!IsDialogMessageW(hwnd,&message)){TranslateMessage(&message);DispatchMessageW(&message);}}ok=true;}
            UnregisterClassW(wc.lpszClassName,wc.hInstance);
        }
        if(view.ack)CloseHandle(view.ack);
        ClearQr(view);SecureZeroMemory(json.data(),json.size()*2);SecureZeroMemory(encoded.data(),encoded.size());
    }
    SecureZeroMemory(base64,sizeof(base64));SecureZeroMemory(&user,sizeof(user));return ok;
}
static bool Enroll(bool emptyPassword=false){
    std::wstring username,domain,sid;DWORD session=0;
    if(!ConsoleSetup(username,domain,sid,session)){
        auto message=SetupFailureText();Error(message.c_str());return false;
    }
    Secret secret;
    wcscpy_s(secret.value.username,username.c_str());wcscpy_s(secret.value.domain,domain.c_str());wcscpy_s(secret.value.user.sid,sid.c_str());
    std::wstring qualified=domain+L"\\"+username;
    if(emptyPassword){
        std::wstring message=L"Current local console account: "+qualified+
            L"\n\nUse this only if this Windows account ALREADY has no password. Stage an empty credential for a real Windows local-console unlock test?\n\nThis is PROVISIONAL: phone-key display and automatic Bluetooth unlock remain disabled until Winlogon actually accepts this credential. An account-restriction error is not password verification. This does not change your account password, blank-password policy, or remote sign-in settings.";
        if(MessageBoxW(nullptr,message.c_str(),L"Confirm existing passwordless account",MB_YESNO|MB_DEFBUTTON2|MB_ICONQUESTION)!=IDYES){enrollmentError=ERROR_CANCELLED;return false;}
    }else{
        wchar_t entered[CREDUI_MAX_USERNAME_LENGTH+1]{};wcscpy_s(entered,qualified.c_str());
        CREDUI_INFOW prompt{};prompt.cbSize=sizeof(prompt);prompt.pszCaptionText=L"Enable iPhone proximity unlock";
        prompt.pszMessageText=L"Enter this local account's Windows PASSWORD (not Windows Hello PIN). After enrollment, the registered phone may unlock this console without per-use confirmation. Windows password/PIN sign-in remains available.";
        BOOL save=FALSE;
        DWORD result=CredUIPromptForCredentialsW(&prompt,L"ProximityUnlock enrollment",nullptr,0,entered,
            CREDUI_MAX_USERNAME_LENGTH+1,secret.value.password,512,&save,
            CREDUI_FLAGS_GENERIC_CREDENTIALS|CREDUI_FLAGS_DO_NOT_PERSIST|CREDUI_FLAGS_EXCLUDE_CERTIFICATES|CREDUI_FLAGS_KEEP_USERNAME|CREDUI_FLAGS_ALWAYS_SHOW_UI);
        if(result==ERROR_CANCELLED){enrollmentError=result;return false;}
        if(result!=NO_ERROR || !secret.value.password[0] || _wcsicmp(entered,qualified.c_str())){
            enrollmentError=result?result:ERROR_INVALID_PARAMETER;
            Error(L"Enter the displayed account's password. If this account already has no password, cancel and use the explicit enroll-empty option instead.");return false;
        }
    }
    // The confirmation/prompt may remain open while users switch or lock sessions.
    if(!ConsoleTarget(sid.c_str(),session,false) || sid!=CurrentSid())return false;
    if(!emptyPassword){
        HANDLE raw=nullptr;
        // One verification only. This does not claim to unlock the workstation.
        if(!LogonUserW(username.c_str(),domain.c_str(),secret.value.password,LOGON32_LOGON_INTERACTIVE,LOGON32_PROVIDER_DEFAULT,&raw)){
            enrollmentError=GetLastError();
            std::wstring message=L"Windows did not validate this local account credential (Win32 error "+std::to_wstring(enrollmentError)+L"). Nothing was enrolled and no retry was made. Your account password and Windows security policies were not changed.";
            Error(message.c_str());return false;
        }
        Handle authenticated(raw);DWORD count=0;GetTokenInformation(authenticated,TokenUser,nullptr,0,&count);std::vector<BYTE> token(count);
        if(!GetTokenInformation(authenticated,TokenUser,token.data(),count,&count) || SidString(reinterpret_cast<TOKEN_USER*>(token.data())->User.Sid)!=sid || !ConsoleTarget(sid.c_str(),session,false))return false;
    }
    memcpy(secret.value.user.magic,"PRXUSER1",8);secret.value.user.version=1;
    if(!Random(&secret.value.user.keyId,sizeof(DWORD)) || !secret.value.user.keyId ||
       !Random(secret.value.user.phone,32) || !Random(secret.value.user.ipc,32))return false;
    {
    EnrollmentLock guard;if(!guard)return false;
    std::wstring machineAcl=L"O:BAG:SYD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)";
    std::wstring userAcl=L"O:"+sid+L"D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;"+sid+L")";
    if(!SetPrivateDirectory(SystemDirectory(),machineAcl) || !SetPrivateDirectory(UserDirectory(),userAcl))return false;
    // Disable before replacing either half: interrupted enrollment fails closed.
    DWORD zero=0;if(!SetReg(L"KeyId",REG_DWORD,&zero,sizeof(zero)) || !SetReg(L"VerifiedKeyId",REG_DWORD,&zero,sizeof(zero)))return false;
    DWORD verified=emptyPassword?0:secret.value.user.keyId;
    bool ok=ProtectFile(SystemDirectory()+L"\\enrollment.bin",&secret.value,sizeof(secret.value),true,L"O:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)") &&
        ProtectFile(UserDirectory()+L"\\enrollment.bin",&secret.value.user,sizeof(secret.value.user),false,L"D:P(A;;FA;;;SY)(A;;FA;;;"+sid+L")") &&
        SetReg(L"TargetSid",REG_SZ,sid.c_str(),static_cast<DWORD>((sid.size()+1)*2)) &&
        SetReg(L"VerifiedKeyId",REG_DWORD,&verified,sizeof(DWORD)) &&
        SetReg(L"KeyId",REG_DWORD,&secret.value.user.keyId,sizeof(DWORD));
    if(!ok){SetReg(L"KeyId",REG_DWORD,&zero,sizeof(zero));Error(L"Enrollment storage failed; automatic unlock remains disabled.");return false;}
    }
    SecureZeroMemory(&secret.value,sizeof(secret.value));
    MessageBoxW(nullptr,emptyPassword?L"Provisional empty credential staged; it has NOT been verified. Phone-key display and Bluetooth automatic unlock remain disabled. Perform one local console request test; only Winlogon's successful authentication result can verify this enrollment. No account password or Windows policy was changed.":L"The password is protected locally. Next, import the displayed random phone key into the iPhone app. No plaintext file is saved. Restart the BLE peer after enrolling or changing the password.",L"Proximity Unlock",MB_OK|MB_ICONINFORMATION);
    if(!emptyPassword)Export();return true;
}
static bool Remove(){
    std::wstring username,domain,sid;DWORD session=0;
    if(!ConsoleSetup(username,domain,sid,session))return false;
    EnrollmentLock guard;if(!guard)return false;
    DWORD zero=0;if(!SetReg(L"KeyId",REG_DWORD,&zero,sizeof(zero)) || !SetReg(L"VerifiedKeyId",REG_DWORD,&zero,sizeof(zero)))return false;
    bool machine=DeleteFileW((SystemDirectory()+L"\\enrollment.bin").c_str()) || GetLastError()==ERROR_FILE_NOT_FOUND;
    bool user=DeleteFileW((UserDirectory()+L"\\enrollment.bin").c_str()) || GetLastError()==ERROR_FILE_NOT_FOUND;
    return machine && user;
}
static bool SelfTest(){
    // Non-secret, reversible local validation. Never changes registration or enrollment.
    BYTE key[32]{},digest[32]{};const char message[]="native-self-test";
    if(!Random(key,32) || !Hmac(key,message,sizeof(message),digest) || !ConstantEqual(digest,digest,32))return false;
    BYTE modified[32]{};memcpy(modified,digest,32);modified[1]^=1;if(ConstantEqual(digest,modified,32))return false;
    DATA_BLOB input{sizeof(message),reinterpret_cast<BYTE*>(const_cast<char*>(message))},encrypted{},plain{};
    if(!CryptProtectData(&input,L"ProximityUnlock non-secret self-test",nullptr,nullptr,nullptr,CRYPTPROTECT_UI_FORBIDDEN,&encrypted))return false;
    bool ok=CryptUnprotectData(&encrypted,nullptr,nullptr,nullptr,nullptr,CRYPTPROTECT_UI_FORBIDDEN,&plain) &&
        plain.cbData==sizeof(message) && !memcmp(plain.pbData,message,sizeof(message));
    if(plain.pbData){SecureZeroMemory(plain.pbData,plain.cbData);LocalFree(plain.pbData);}LocalFree(encrypted.pbData);
    // Longest enrollment JSON (10-digit key id, 44-char base64) must fit a version 6 (41x41) code with ECC M,
    // and the top-left finder pattern must be in place. Dummy, non-secret payload.
    KeyView view;std::wstring sample=L"{\"version\":1,\"keyID\":4294967295,\"secret\":\""+std::wstring(43,L'A')+L"=\"}";
    ok=ok && EncodeQr(sample,view) && view.size==41 && view.modules[0] && !view.modules[1*41+1] && view.modules[3*41+3] && !view.modules[7*41+7];
    ClearQr(view);
    // Acknowledgement event: the SDDL parses, and a separate open can signal it the way win_peer.py does.
    PSECURITY_DESCRIPTOR sd=nullptr;
    ok=ok && ConvertStringSecurityDescriptorToSecurityDescriptorW(kAckEventSddl,SDDL_REVISION_1,&sd,nullptr);
    if(sd)LocalFree(sd);
    if(HANDLE event=CreateAckEvent()){
        HANDLE other=OpenEventW(EVENT_MODIFY_STATE,FALSE,kEnrollAckEvent);
        ok=ok && other && SetEvent(other) && WaitForSingleObject(event,0)==WAIT_OBJECT_0;
        if(other)CloseHandle(other);
        ResetEvent(event);CloseHandle(event);
    }else ok=false;
    SecureZeroMemory(key,32);return ok;
}
int wmain(int argc,wchar_t** argv){
    CoInitializeEx(nullptr,COINIT_APARTMENTTHREADED);
    std::wstring command=argc==2?argv[1]:L"status";bool ok=false;
    if(command==L"enroll")ok=Enroll();
    else if(command==L"enroll-empty")ok=Enroll(true);
    else if(command==L"remove")ok=Remove();
    else if(command==L"export")ok=Export();
    else if(command==L"request"){
        RequestDiagnostic diagnostic;ok=RequestUnlock(&diagnostic);
        printf("{\"success\":%s,\"stage\":\"%s\",\"win32Error\":%lu}\n",ok?"true":"false",diagnostic.stage,diagnostic.error);
        CoUninitialize();return ok?0:1;
    }
    else if(command==L"selftest")ok=SelfTest();
    else if(command==L"setup-status"){
        std::wstring username,domain,sid;DWORD session=0;PrintSetup(InspectSetup(username,domain,sid,session));CoUninitialize();return 0;
    }
    else if(command==L"status"){
        UserEnrollment user{};std::wstring username,domain,sid;DWORD session=0;
        bool local=ConsoleAccount(username,domain,sid,session) && sid==CurrentSid();
        bool enrolled=ReadUser(user);ok=local && enrolled && RegistryEnabled(user);
        bool provisional=local && enrolled && RegistryEnabled(user,true) && !ok;
        printf("{\"localConsole\":%s,\"enrolled\":%s,\"available\":%s,\"pendingValidation\":%s,\"locked\":%s,\"session\":%lu}\n",
            local?"true":"false",enrolled?"true":"false",ok?"true":"false",provisional?"true":"false",local&&ConsoleTarget(sid.c_str(),session,true)?"true":"false",session);
        SecureZeroMemory(&user,sizeof(user));CoUninitialize();return ok?0:1;
    }else{fwprintf(stderr,L"Usage: ProximityUnlock.exe [status|setup-status|enroll|enroll-empty|remove|export|request|selftest]\n");CoUninitialize();return 2;}
    printf("{\"success\":%s,\"win32Error\":%lu}\n",ok?"true":"false",enrollmentError);CoUninitialize();return ok?0:(enrollmentError?static_cast<int>(enrollmentError):1);
}
