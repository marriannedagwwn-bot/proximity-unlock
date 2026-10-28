#pragma once
#define WIN32_LEAN_AND_MEAN
#define SECURITY_WIN32
#define NOMINMAX
#include <windows.h>
#include <wincrypt.h>
#include <bcrypt.h>
#include <wtsapi32.h>
#include <sddl.h>
#include <shlobj.h>
#include <ntsecapi.h>
#include <security.h>
#include <wincred.h>
#include <credentialprovider.h>
#include <string>
#include <vector>
#include <memory>
#include <cstring>
#include <algorithm>

namespace proximity {
inline constexpr wchar_t kClsid[] = L"{908BDBA7-6A55-4C85-B4AB-33B7D99A76C0}";
inline constexpr CLSID kProviderClsid = {0x908bdba7,0x6a55,0x4c85,{0xb4,0xab,0x33,0xb7,0xd9,0x9a,0x76,0xc0}};
inline constexpr wchar_t kRegistry[] = L"SOFTWARE\\ProximityUnlock";
inline constexpr wchar_t kUserFile[] = L"enrollment.bin";
// No password in UserEnrollment. A different random key authorizes local IPC.
#pragma pack(push, 1)
struct UserEnrollment {
    char magic[8]; DWORD version; DWORD keyId;
    BYTE phone[32]; BYTE ipc[32]; wchar_t sid[192];
};
struct SystemEnrollment {
    UserEnrollment user; wchar_t username[256]; wchar_t domain[256]; wchar_t password[512];
};
struct Challenge {
    char magic[8]; DWORD version; DWORD keyId; DWORD session;
    ULONGLONG expires; BYTE nonce[32]; wchar_t sid[192]; BYTE mac[32];
};
struct Request { char magic[8]; BYTE mac[32]; };
#pragma pack(pop)
static_assert(sizeof(UserEnrollment) == 464);
static_assert(sizeof(Challenge) == 476);

struct Handle {
    HANDLE h = INVALID_HANDLE_VALUE;
    Handle() = default;
    explicit Handle(HANDLE v) : h(v) {}
    ~Handle() { if(h && h != INVALID_HANDLE_VALUE) CloseHandle(h); }
    Handle(const Handle&) = delete;
    Handle& operator=(const Handle&) = delete;
    explicit operator bool() const { return h && h != INVALID_HANDLE_VALUE; }
    operator HANDLE() const { return h; }
};
struct Secret {
    SystemEnrollment value{};
    ~Secret() { SecureZeroMemory(&value, sizeof(value)); }
};
bool Random(void* data, DWORD size);
bool Hmac(const BYTE key[32], const void* data, DWORD size, BYTE mac[32]);
bool ConstantEqual(const BYTE* a, const BYTE* b, size_t size);
std::wstring SidString(PSID sid);
std::wstring CurrentSid();
std::wstring KnownPath(REFKNOWNFOLDERID id);
std::wstring UserDirectory();
std::wstring SystemDirectory();
std::wstring InstallDirectory();
std::wstring PipeName(DWORD session);
bool ReadFileBytes(const std::wstring& path, std::vector<BYTE>& bytes);
bool ProtectFile(const std::wstring& path, const void* data, DWORD size, bool machine, const std::wstring& sddl);
bool UnprotectFile(const std::wstring& path, void* data, DWORD size);
bool ReadUser(UserEnrollment& user);
bool ReadSystem(SystemEnrollment& system);
bool VerificationAllows(DWORD keyId, DWORD verifiedKeyId, bool allowPending);
bool VerificationProofMatches(DWORD submittedKeyId, DWORD storedKeyId, DWORD verifiedKeyId,
                              bool emptyPassword, NTSTATUS status, NTSTATUS substatus);
// Owned by the exact Credential object that serialized. A sibling or newly
// created Credential has no proof; consuming a result clears it permanently.
class VerificationSubmission {
    DWORD keyId = 0;
public:
    void Serialized(DWORD submitted, bool provisional) { keyId = provisional ? submitted : 0; }
    DWORD Consume() { DWORD result = keyId; keyId = 0; return result; }
};
bool RegistryEnabled(const UserEnrollment& user, bool allowPending = false);
bool MarkConsoleVerified(DWORD submittedKeyId, const std::wstring& sid, DWORD session,
                         NTSTATUS status, NTSTATUS substatus);
struct EnrollmentLock {
    Handle mutex;
    bool locked = false;
    EnrollmentLock();
    ~EnrollmentLock();
    explicit operator bool() const { return locked; }
};
// Exact active local console owner; false for logon/no user, RDP, switch-away or unknown state.
bool ConsoleTarget(const wchar_t* expectedSid, DWORD session, bool locked);
bool ConsoleTargetForInitialization(const wchar_t* expectedSid, DWORD session);
bool ConsoleAccount(std::wstring& username, std::wstring& domain, std::wstring& sid, DWORD& session);
bool IsSystem();
bool IsAdministrator();
bool SetPrivateDirectory(const std::wstring& path, const std::wstring& sddl);
bool Transfer(HANDLE pipe, void* data, DWORD size, bool writing, DWORD timeout = 1200);
struct RequestDiagnostic { const char* stage = "not-started"; DWORD error = 0; };
bool RequestUnlock(RequestDiagnostic* diagnostic = nullptr);
void NativeTrace(const wchar_t* stage, DWORD error = 0, HRESULT result = S_OK,
                 NTSTATUS status = 0, NTSTATUS substatus = 0, DWORD detail = 0);
HRESULT Serialize(const SystemEnrollment& secret, CREDENTIAL_PROVIDER_USAGE_SCENARIO scenario,
                  CREDENTIAL_PROVIDER_CREDENTIAL_SERIALIZATION* result);
}
