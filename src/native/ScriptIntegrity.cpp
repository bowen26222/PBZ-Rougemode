#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <bcrypt.h>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <cwchar>
#include "ScriptIntegrity.generated.h"

extern "C" __declspec(dllexport) int pbz_apply_script_integrity(void*);

namespace {
using pbz_integrity::Fingerprint;
constexpr size_t kPatchCount = sizeof(pbz_integrity::patches) / sizeof(pbz_integrity::patches[0]);
constexpr uintptr_t kManifestRva = 0x0bec50f0;
constexpr size_t kRecordCount = 241;
constexpr size_t kStride = 88;
constexpr size_t kPathCapacity = 32768;
constexpr size_t kManifestPathCapacity = 512;
static_assert(sizeof(void*) == 8 && sizeof(wchar_t) == 2, "Windows x64 required");
static_assert(kPatchCount == 15 && sizeof(Fingerprint) == 80, "Unexpected generated manifest layout");
static_assert(offsetof(Fingerprint, wrapped_length) == 8 && offsetof(Fingerprint, raw_hash) == 16 &&
              offsetof(Fingerprint, wrapped_hash) == 48, "Unexpected fingerprint offsets");
SRWLOCK g_lock = SRWLOCK_INIT;

struct Record {
    uintptr_t address;
    Fingerprint before;
    bool attempted;
};
struct Page {
    uintptr_t address;
    DWORD original;
    bool changed;
};
struct Transaction {
    Record records[kPatchCount];
    Page pages[kPatchCount * 2];
    size_t page_count;
    DWORD page_size;
    HANDLE executable;
    HANDLE pak;
    HANDLE status;
    wchar_t status_path[kPathCapacity];
};

bool ReadMemory(uintptr_t address, void* out, size_t size) noexcept {
    SIZE_T read = 0;
    return ReadProcessMemory(GetCurrentProcess(), reinterpret_cast<const void*>(address), out, size, &read) && read == size;
}
bool WriteMemory(uintptr_t address, const Fingerprint& value) noexcept {
    SIZE_T written = 0;
    return WriteProcessMemory(GetCurrentProcess(), reinterpret_cast<void*>(address), &value, sizeof(value), &written) && written == sizeof(value);
}
bool Equal(const Fingerprint& a, const Fingerprint& b) noexcept {
    return std::memcmp(&a, &b, sizeof(a)) == 0;
}
bool InImage(uintptr_t base, size_t size, uintptr_t address, size_t length) noexcept {
    return address >= base && address - base <= size && length <= size - (address - base);
}
bool Readable(DWORD protection) noexcept {
    if (protection & (PAGE_GUARD | PAGE_NOACCESS)) return false;
    switch (protection & 0xff) {
    case PAGE_READONLY: case PAGE_READWRITE: case PAGE_WRITECOPY:
    case PAGE_EXECUTE_READ: case PAGE_EXECUTE_READWRITE: case PAGE_EXECUTE_WRITECOPY: return true;
    default: return false;
    }
}
bool MappedImage(uintptr_t base, uintptr_t address, size_t length) noexcept {
    while (length) {
        MEMORY_BASIC_INFORMATION region{};
        if (!VirtualQuery(reinterpret_cast<const void*>(address), &region, sizeof(region)) ||
            region.AllocationBase != reinterpret_cast<void*>(base) || region.Type != MEM_IMAGE ||
            region.State != MEM_COMMIT || !Readable(region.Protect)) return false;
        const uintptr_t region_base = reinterpret_cast<uintptr_t>(region.BaseAddress);
        if (address < region_base || address - region_base >= region.RegionSize) return false;
        const size_t available = region.RegionSize - (address - region_base);
        const size_t count = length < available ? length : available;
        if (address > UINTPTR_MAX - count) return false;
        address += count;
        length -= count;
    }
    return true;
}

// Fixed-size streaming buffer; held read-only handles prevent file replacement/writes
// between hashing and committing the in-memory fingerprints.
bool HashMatches(HANDLE file, const unsigned char expected[32]) noexcept {
    if (file == INVALID_HANDLE_VALUE || file == nullptr) return false;
    LARGE_INTEGER length{}, zero{};
    if (!GetFileSizeEx(file, &length) || length.QuadPart < 0 || !SetFilePointerEx(file, zero, nullptr, FILE_BEGIN)) return false;
    BCRYPT_ALG_HANDLE algorithm = nullptr;
    BCRYPT_HASH_HANDLE hash = nullptr;
    unsigned char digest[32]{};
    unsigned char buffer[65536];
    bool ok = BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0) >= 0;
    // Windows 7+ BCrypt owns the incremental hash object's storage with nullptr/0.
    if (ok) ok = BCryptCreateHash(algorithm, &hash, nullptr, 0, nullptr, 0, 0) >= 0;
    LONGLONG remaining = length.QuadPart;
    while (ok && remaining) {
        const DWORD wanted = remaining < static_cast<LONGLONG>(sizeof(buffer)) ? static_cast<DWORD>(remaining) : static_cast<DWORD>(sizeof(buffer));
        DWORD received = 0;
        ok = ReadFile(file, buffer, wanted, &received, nullptr) && received == wanted &&
             BCryptHashData(hash, buffer, received, 0) >= 0;
        remaining -= received;
    }
    DWORD extra = 0;
    if (ok) ok = ReadFile(file, buffer, 1, &extra, nullptr) && extra == 0 &&
                 BCryptFinishHash(hash, digest, sizeof(digest), 0) >= 0 && std::memcmp(digest, expected, sizeof(digest)) == 0;
    if (hash) BCryptDestroyHash(hash);
    if (algorithm) BCryptCloseAlgorithmProvider(algorithm, 0);
    return ok;
}

bool WriteStatus(HANDLE file, const char* message) noexcept {
    LARGE_INTEGER zero{};
    DWORD written = 0;
    const DWORD length = static_cast<DWORD>(std::strlen(message));
    return file && file != INVALID_HANDLE_VALUE && SetFilePointerEx(file, zero, nullptr, FILE_BEGIN) &&
           SetEndOfFile(file) && WriteFile(file, message, length, &written, nullptr) && written == length && FlushFileBuffers(file);
}

bool OpenStatus(Transaction& tx) noexcept {
    HMODULE self = nullptr;
    if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
        reinterpret_cast<LPCWSTR>(&pbz_apply_script_integrity), &self)) return false;
    const DWORD length = GetModuleFileNameW(self, tx.status_path, static_cast<DWORD>(kPathCapacity));
    constexpr wchar_t suffix[] = L".status";
    if (!length || length >= kPathCapacity - (sizeof(suffix) / sizeof(wchar_t))) {
        tx.status_path[0] = L'\0'; // Cleanup must never mistake the DLL path for its status.
        return false;
    }
    std::memcpy(tx.status_path + length, suffix, sizeof(suffix));
    tx.status = CreateFileW(tx.status_path, GENERIC_WRITE, FILE_SHARE_READ, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    return WriteStatus(tx.status, "error: integrity operation incomplete\n");
}

bool ReadImagePath(uintptr_t base, size_t image_size, uintptr_t address, wchar_t (&path)[kManifestPathCapacity]) noexcept {
    if (address % alignof(wchar_t)) return false;
    size_t used = 0;
    while (used < kManifestPathCapacity) {
        MEMORY_BASIC_INFORMATION region{};
        if (!InImage(base, image_size, address, sizeof(wchar_t)) ||
            !VirtualQuery(reinterpret_cast<void*>(address), &region, sizeof(region)) ||
            region.AllocationBase != reinterpret_cast<void*>(base) || region.Type != MEM_IMAGE ||
            region.State != MEM_COMMIT || !Readable(region.Protect)) return false;
        const uintptr_t region_base = reinterpret_cast<uintptr_t>(region.BaseAddress);
        if (address < region_base || address - region_base >= region.RegionSize) return false;
        size_t bytes = region.RegionSize - (address - region_base);
        const size_t image_remaining = image_size - (address - base);
        if (bytes > image_remaining) bytes = image_remaining;
        size_t count = bytes / sizeof(wchar_t);
        if (count > 64) count = 64;
        if (count > kManifestPathCapacity - used) count = kManifestPathCapacity - used;
        if (!count || !ReadMemory(address, path + used, count * sizeof(wchar_t))) return false;
        for (size_t i = 0; i < count; ++i)
            if (!path[used + i]) return used + i != 0;
        used += count;
        address += count * sizeof(wchar_t);
    }
    return false;
}

const char* Prepare(Transaction& tx) noexcept {
    wchar_t executable_path[kPathCapacity];
    DWORD length = GetModuleFileNameW(nullptr, executable_path, static_cast<DWORD>(kPathCapacity));
    if (!length || length >= kPathCapacity) return "error: executable path unavailable\n";
    tx.executable = CreateFileW(executable_path, GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, FILE_FLAG_SEQUENTIAL_SCAN, nullptr);
    if (!HashMatches(tx.executable, pbz_integrity::executable_hash)) return "error: unsupported executable SHA256 or unreadable file\n";
    wchar_t* separator = std::wcsrchr(executable_path, L'\\');
    if (!separator) return "error: executable directory unavailable\n";
    constexpr wchar_t relative_pak[] = L"..\\..\\ProjectPBZ\\Content\\Paks\\~mods\\pakchunk999-PBZRogueSkills_P.pak";
    const size_t prefix = static_cast<size_t>(separator + 1 - executable_path);
    if (prefix + sizeof(relative_pak) / sizeof(wchar_t) > kPathCapacity) return "error: pak path too long\n";
    std::memcpy(executable_path + prefix, relative_pak, sizeof(relative_pak));
    wchar_t pak_path[kPathCapacity];
    length = GetFullPathNameW(executable_path, static_cast<DWORD>(kPathCapacity), pak_path, nullptr);
    if (!length || length >= kPathCapacity) return "error: pak path unavailable\n";
    tx.pak = CreateFileW(pak_path, GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, FILE_FLAG_SEQUENTIAL_SCAN, nullptr);
    if (!HashMatches(tx.pak, pbz_integrity::pak_hash)) return "error: installed pak SHA256 mismatch or unreadable file\n";

    const uintptr_t base = reinterpret_cast<uintptr_t>(GetModuleHandleW(nullptr));
    IMAGE_DOS_HEADER dos{};
    if (!base || !MappedImage(base, base, sizeof(dos)) || !ReadMemory(base, &dos, sizeof(dos)) ||
        dos.e_magic != IMAGE_DOS_SIGNATURE || dos.e_lfanew < static_cast<LONG>(sizeof(dos)) || dos.e_lfanew > 0x100000)
        return "error: invalid executable DOS header\n";
    IMAGE_NT_HEADERS64 nt{};
    const uintptr_t nt_address = base + static_cast<uintptr_t>(dos.e_lfanew);
    if (!MappedImage(base, nt_address, sizeof(nt)) || !ReadMemory(nt_address, &nt, sizeof(nt)) ||
        nt.Signature != IMAGE_NT_SIGNATURE || nt.FileHeader.Machine != IMAGE_FILE_MACHINE_AMD64 ||
        nt.FileHeader.SizeOfOptionalHeader != sizeof(IMAGE_OPTIONAL_HEADER64) || nt.OptionalHeader.Magic != IMAGE_NT_OPTIONAL_HDR64_MAGIC ||
        !nt.FileHeader.NumberOfSections || !nt.OptionalHeader.SectionAlignment ||
        nt.OptionalHeader.SizeOfImage % nt.OptionalHeader.SectionAlignment ||
        nt.OptionalHeader.SizeOfHeaders > nt.OptionalHeader.SizeOfImage || base > UINTPTR_MAX - nt.OptionalHeader.SizeOfImage)
        return "error: invalid x64 executable image\n";
    // Compare the mapped image geometry with the already hash-pinned disk PE header.
    LARGE_INTEGER offset{};
    offset.QuadPart = dos.e_lfanew;
    IMAGE_NT_HEADERS64 disk_nt{};
    DWORD received = 0;
    if (!SetFilePointerEx(tx.executable, offset, nullptr, FILE_BEGIN) ||
        !ReadFile(tx.executable, &disk_nt, sizeof(disk_nt), &received, nullptr) || received != sizeof(disk_nt) ||
        std::memcmp(&nt, &disk_nt, sizeof(nt)) != 0) return "error: mapped executable header differs from pinned file\n";
    const size_t image_size = nt.OptionalHeader.SizeOfImage;
    const uintptr_t manifest = base + kManifestRva;
    if (!InImage(base, image_size, nt_address, sizeof(nt)) ||
        !InImage(base, image_size, manifest, kRecordCount * kStride) ||
        !MappedImage(base, manifest, kRecordCount * kStride)) return "error: manifest outside readable executable image\n";

    for (size_t i = 0; i < kPatchCount; ++i) {
        const auto& patch = pbz_integrity::patches[i];
        if (!patch.path || !patch.path[0] || std::wcslen(patch.path) >= kManifestPathCapacity ||
            patch.original.raw_length > UINT64_MAX - 66 || patch.patched.raw_length > UINT64_MAX - 66 ||
            patch.original.wrapped_length != patch.original.raw_length + 66 ||
            patch.patched.wrapped_length != patch.patched.raw_length + 66 || Equal(patch.original, patch.patched))
            return "error: invalid generated patch manifest\n";
        for (size_t j = 0; j < i; ++j)
            if (std::wcscmp(patch.path, pbz_integrity::patches[j].path) == 0) return "error: duplicate generated patch path\n";
    }
    wchar_t previous[kManifestPathCapacity]{};
    for (size_t i = 0; i < kRecordCount; ++i) {
        const uintptr_t record = manifest + i * kStride;
        uintptr_t path_address = 0;
        wchar_t path[kManifestPathCapacity];
        if (!ReadMemory(record, &path_address, sizeof(path_address)) || !ReadImagePath(base, image_size, path_address, path) ||
            (i && std::wcscmp(previous, path) >= 0)) return "error: invalid manifest path table\n";
        std::memcpy(previous, path, (std::wcslen(path) + 1) * sizeof(wchar_t));
        for (size_t j = 0; j < kPatchCount; ++j) {
            if (std::wcscmp(path, pbz_integrity::patches[j].path) != 0) continue;
            tx.records[j].address = record + sizeof(uintptr_t);
            if (!ReadMemory(tx.records[j].address, &tx.records[j].before, sizeof(Fingerprint))) return "error: unreadable selected fingerprint\n";
        }
    }
    size_t originals = 0, patched = 0;
    for (size_t i = 0; i < kPatchCount; ++i) {
        if (!tx.records[i].address) return "error: selected manifest path missing\n";
        if (Equal(tx.records[i].before, pbz_integrity::patches[i].original)) ++originals;
        else if (Equal(tx.records[i].before, pbz_integrity::patches[i].patched)) ++patched;
        else return "error: selected manifest fingerprint mismatch\n";
    }
    if (patched == kPatchCount) return nullptr;
    if (originals != kPatchCount) return "error: mixed original and patched manifest\n";
    SYSTEM_INFO system{};
    GetSystemInfo(&system);
    tx.page_size = system.dwPageSize;
    if (tx.page_size < sizeof(Fingerprint) || (tx.page_size & (tx.page_size - 1))) return "error: unsupported page size\n";
    for (const auto& record : tx.records) {
        const uintptr_t first = record.address & ~(static_cast<uintptr_t>(tx.page_size) - 1);
        const uintptr_t last = (record.address + sizeof(Fingerprint) - 1) & ~(static_cast<uintptr_t>(tx.page_size) - 1);
        for (uintptr_t address = first;; address += tx.page_size) {
            size_t i = 0;
            while (i < tx.page_count && tx.pages[i].address != address) ++i;
            if (i == tx.page_count) {
                MEMORY_BASIC_INFORMATION region{};
                if (tx.page_count == kPatchCount * 2 || !InImage(base, image_size, address, tx.page_size) ||
                    !MappedImage(base, address, tx.page_size) || !VirtualQuery(reinterpret_cast<void*>(address), &region, sizeof(region)))
                    return "error: selected page mapping invalid\n";
                tx.pages[tx.page_count++] = {address, region.Protect, false};
            }
            if (address == last) break;
        }
    }
    return nullptr;
}

DWORD Writable(DWORD original) noexcept {
    const DWORD access = original & 0xff;
    return ((access == PAGE_EXECUTE_READ || access == PAGE_EXECUTE_READWRITE || access == PAGE_EXECUTE_WRITECOPY)
        ? PAGE_EXECUTE_READWRITE : PAGE_READWRITE) | (original & (PAGE_NOCACHE | PAGE_WRITECOMBINE));
}
bool RestorePages(Transaction& tx) noexcept {
    bool ok = true;
    for (size_t i = tx.page_count; i > 0; --i) {
        auto& page = tx.pages[i - 1];
        if (!page.changed) continue;
        DWORD ignored = 0;
        if (VirtualProtect(reinterpret_cast<void*>(page.address), tx.page_size, page.original, &ignored)) page.changed = false;
        else ok = false;
    }
    return ok;
}
const char* Apply(Transaction& tx) noexcept {
    for (size_t i = 0; i < tx.page_count; ++i) {
        auto& page = tx.pages[i];
        DWORD old = 0;
        if (!VirtualProtect(reinterpret_cast<void*>(page.address), tx.page_size, Writable(page.original), &old))
            return "error: cannot make selected page writable\n";
        page.changed = true;
        const bool unchanged = old == page.original;
        page.original = old;
        if (!unchanged) return "error: selected page protection changed concurrently\n";
    }
    // No writes until every requested record and every page has been checked.
    for (const auto& record : tx.records) {
        Fingerprint current{};
        if (!ReadMemory(record.address, &current, sizeof(current)) || !Equal(current, record.before))
            return "error: selected fingerprint changed concurrently\n";
    }
    if (!tx.page_count) return nullptr; // Entire set was already applied.
    for (size_t i = 0; i < kPatchCount; ++i) {
        tx.records[i].attempted = true; // Includes a potentially partial WriteProcessMemory.
        if (!WriteMemory(tx.records[i].address, pbz_integrity::patches[i].patched)) return "error: fingerprint write failed\n";
    }
    for (size_t i = 0; i < kPatchCount; ++i) {
        Fingerprint current{};
        if (!ReadMemory(tx.records[i].address, &current, sizeof(current)) || !Equal(current, pbz_integrity::patches[i].patched))
            return "error: fingerprint readback failed\n";
    }
    if (!RestorePages(tx)) return "error: page protection restoration failed\n";
    return nullptr;
}

bool Rollback(Transaction& tx) noexcept {
    bool writes = false;
    for (const auto& record : tx.records) writes = writes || record.attempted;
    bool ok = true;
    if (writes) {
        for (size_t i = 0; i < tx.page_count; ++i) {
            auto& page = tx.pages[i];
            DWORD ignored = 0;
            if (VirtualProtect(reinterpret_cast<void*>(page.address), tx.page_size, Writable(page.original), &ignored)) page.changed = true;
            else ok = false;
        }
        for (const auto& record : tx.records) {
            if (!record.attempted) continue;
            Fingerprint current{};
            if (!WriteMemory(record.address, record.before)) ok = false;
            if (!ReadMemory(record.address, &current, sizeof(current)) || !Equal(current, record.before)) ok = false;
        }
    }
    return RestorePages(tx) && ok;
}
void Close(HANDLE file) noexcept {
    if (file && file != INVALID_HANDLE_VALUE) CloseHandle(file);
}
} // namespace

// No Lua imports or Lua stack access: package.loadlib can call this zero-result C function.
// All game memory accesses use bounded Win32 APIs; SEH also contains unexpected faults.
extern "C" __declspec(dllexport) int pbz_apply_script_integrity(void*) {
    AcquireSRWLockExclusive(&g_lock);
    Transaction tx{};
    const char* error = "error: status file unavailable\n";
    bool committed = false;
    __try {
        if (OpenStatus(tx)) {
            error = Prepare(tx);
            if (!error) error = Apply(tx);
            if (!error) {
                committed = WriteStatus(tx.status, "ok\n");
                if (!committed) error = "error: success status could not be persisted\n";
            }
        }
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        error = "error: native integrity operation fault\n";
    }
    if (!committed) {
        __try {
            if (!Rollback(tx)) error = "error: rollback or page protection restoration failed\n";
        } __except (EXCEPTION_EXECUTE_HANDLER) {
            error = "error: native rollback fault\n";
        }
        // Never leave an apparent success if persisting its status failed.
        if (!WriteStatus(tx.status, error)) {
            Close(tx.status);
            tx.status = nullptr;
            if (tx.status_path[0]) DeleteFileW(tx.status_path);
        }
    }
    Close(tx.status);
    Close(tx.pak);
    Close(tx.executable);
    ReleaseSRWLockExclusive(&g_lock);
    return 0;
}
