using System.Text;
using CUE4Parse.Compression;
using CUE4Parse.Encryption.Aes;
using CUE4Parse.FileProvider;
using CUE4Parse.FileProvider.Objects;
using CUE4Parse.MappingsProvider.Usmap;
using CUE4Parse.UE4.Objects.Core.Misc;
using CUE4Parse.UE4.Versions;
using Newtonsoft.Json;

// API references: KintaroModding/phantombladezero_pbzusmap/src/usmap_offline;
// FabianFG/CUE4Parse: DefaultFileProvider, AbstractVfsFileProvider, GameFile, IPackage,
// OodleHelper and README's Newtonsoft.Json export example. No asset conversion is used.
internal static class Program
{
    private const long MaxSelectedFileBytes = 32L * 1024 * 1024;
    private static readonly StringComparison FileSystemComparison = OperatingSystem.IsWindows()
        ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;

    public static int Main(string[] args)
    {
        // Dependency exception messages and structured logs may include encryption material.
        // Do not configure any sinks or echo arguments/secrets, even on failure.
        Serilog.Log.Logger = new Serilog.LoggerConfiguration().CreateLogger();
        CUE4Parse.Globals.FatalObjectSerializationErrors = true;
        try
        {
            if (args.Length == 0 || args is ["--help"] or ["-h"])
            {
                Console.WriteLine(Help);
                return args.Length == 0 ? 2 : 0;
            }
            return Run(Options.Parse(args));
        }
        catch (UsageException ex)
        {
            Console.Error.WriteLine(ex.Message);
            return 2;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"Operation failed ({ex.GetType().Name}). Check input access, engine version, AES/mapping and compression prerequisites. Dependency messages are suppressed to protect keys.");
            return 1;
        }
    }

    private static int Run(Options options)
    {
        string paks = Path.GetFullPath(options.Required("--paks"));
        if (!Directory.Exists(paks)) throw new UsageException("Paks directory does not exist.");
        string output = Path.TrimEndingDirectorySeparator(Path.GetFullPath(options.Required("--out")));
        if (Within(output, paks) || Within(paks, output))
            throw new UsageException("Output directory must not overlap the source Paks directory.");

        string? usmap = InputFile(options.Value("--usmap"));
        string? oodle = InputFile(options.Value("--oodle"));
        string? aesFile = InputFile(options.Value("--aes-file"));
        foreach (string? input in new[] { usmap, oodle, aesFile })
            if (input != null && Within(input, output))
                throw new UsageException("Output directory must not contain a supplied prerequisite file.");

        if (!Enum.TryParse(options.Value("--game") ?? "GAME_UE5_7", out EGame game) || !Enum.IsDefined(game))
            throw new UsageException("Unknown --game enum name.");
        if (options.Command == "export-json" && usmap == null)
            throw new UsageException("export-json requires --usmap for this game's unversioned assets.");

        var key = ReadKey(options, aesFile);
        // The instance overload never invokes OodleHelper's automatic DLL downloader.
        if (oodle != null) OodleHelper.Initialize(new OodleDotNet.Oodle(oodle));
        using var provider = new DefaultFileProvider(paks, SearchOption.TopDirectoryOnly, new VersionContainer(game));
        provider.ReadScriptData = options.Command == "export-json";
        if (usmap != null) provider.MappingsContainer = new FileUsmapTypeMappingsProvider(usmap);
        provider.Initialize();
        provider.Mount();
        if (key != null) provider.SubmitKey(ParseKeyGuid(options.Value("--key-guid")), key);
        provider.PostMount();

        Console.Error.WriteLine($"Mounted archives: {provider.MountedVfs.Count}; unmounted: {provider.UnloadedVfs.Count}; required key GUIDs: {provider.RequiredKeys.Count}; indexed files: {provider.Files.Count}.");
        foreach (var reader in provider.UnloadedVfs)
            Console.Error.WriteLine($"Unmounted archive: {reader.Name}; encrypted index: {reader.IsEncrypted}; key GUID: {reader.EncryptionKeyGuid}.");
        if (provider.Files.Count == 0)
            throw new UsageException("No files were indexed. No extraction was performed. Check archive/version support and whether an AES key is required.");

        if (options.Command == "list")
        {
            string? contains = options.Value("--contains");
            var files = provider.Files.Values.Where(f => contains == null || f.Path.Contains(contains, StringComparison.OrdinalIgnoreCase));
            using var stream = CreateOutput(output, options.Value("--list-file") ?? "paths.txt");
            using var writer = new StreamWriter(stream, new UTF8Encoding(false));
            int count = 0;
            foreach (var file in files.OrderBy(f => f.Path, StringComparer.Ordinal))
            {
                writer.WriteLine(file.Path);
                count++;
            }
            Console.Error.WriteLine($"Listed {count} mounted paths. Only explicitly selected files can be exported.");
        }
        else
        {
            foreach (string requested in options.Paths)
            {
                // Use the original indexed path, not FixPath's /Game aliases or wildcard matching.
                if (!provider.Files.TryGetValue(requested, out GameFile? file) ||
                    !string.Equals(file.Path, requested, StringComparison.Ordinal))
                    throw new UsageException("Selected path is not an exact indexed path. Use list first (matching is case-sensitive).");
                if (file.Size < 0 || file.Size > MaxSelectedFileBytes)
                    throw new UsageException("Selected file exceeds the 32 MiB per-file safety limit.");
                if (options.Command == "export-text")
                {
                    if (!file.Extension.Equals("js", StringComparison.OrdinalIgnoreCase) &&
                        !file.Extension.Equals("json", StringComparison.OrdinalIgnoreCase) &&
                        !file.Extension.Equals("ini", StringComparison.OrdinalIgnoreCase))
                        throw new UsageException("export-text only permits .js, .json and .ini paths.");
                    // Preserve source bytes/encoding. There is no text decoding or rewriting.
                    using var reader = file.CreateReader();
                    if (reader.Length > MaxSelectedFileBytes)
                        throw new UsageException("Selected text exceeds the 32 MiB safety limit.");
                    using var destination = CreateOutput(output, file.Path);
                    reader.CopyTo(destination);
                }
                else
                {
                    if (!file.Extension.Equals("uasset", StringComparison.OrdinalIgnoreCase) &&
                        !file.Extension.Equals("umap", StringComparison.OrdinalIgnoreCase))
                        throw new UsageException("export-json only permits explicit .uasset or .umap paths.");
                    var package = provider.LoadPackage(file);
                    if (!package.CanDeserialize)
                        throw new UsageException("Package cannot be deserialized with the supplied version/mappings.");
                    // Deserialize before creating output, so a missing mapping cannot leave a fake JSON success.
                    var exports = package.ExportsLazy.Select(export => export.Value).ToArray();
                    using var stream = CreateOutput(output, file.Path + ".json");
                    using var text = new StreamWriter(stream, new UTF8Encoding(false));
                    using var json = new JsonTextWriter(text) { Formatting = Formatting.Indented };
                    JsonSerializer.CreateDefault().Serialize(json, exports);
                }
                Console.Error.WriteLine($"Exported: {file.Path}");
            }
        }

        if (provider.UnloadedVfs.Count != 0)
        {
            Console.Error.WriteLine("Result is partial: one or more archives remain unmounted. No key is assumed or discovered automatically.");
            return 3;
        }
        return 0;
    }

    private static FAesKey? ReadKey(Options options, string? aesFile)
    {
        string? env = options.Value("--aes-env");
        if (env != null && aesFile != null)
            throw new UsageException("Choose either --aes-env or --aes-file, not both.");
        string? secret = aesFile != null ? File.ReadAllText(aesFile).Trim()
            : env != null ? Environment.GetEnvironmentVariable(env)?.Trim() : null;
        if (env == null && aesFile == null)
        {
            if (options.Value("--key-guid") != null) throw new UsageException("--key-guid requires an AES source.");
            return null;
        }
        if (string.IsNullOrWhiteSpace(secret)) throw new UsageException("The supplied AES source is empty or unset.");
        try { return new FAesKey(secret); }
        catch (Exception) { throw new UsageException("AES must contain 64 hexadecimal digits, optionally prefixed by 0x. Value is not logged."); }
    }

    private static FGuid ParseKeyGuid(string? value)
    {
        if (value == null) return new FGuid();
        if (!Guid.TryParse(value, out Guid guid)) throw new UsageException("--key-guid must be a GUID (default: all zeroes).");
        return new FGuid(guid.ToString("N"));
    }

    private static string? InputFile(string? value)
    {
        if (value == null) return null;
        string full = Path.GetFullPath(value);
        if (!File.Exists(full)) throw new UsageException("A supplied prerequisite file does not exist.");
        return full;
    }

    private static bool Within(string candidate, string root) =>
        string.Equals(candidate, root, FileSystemComparison) ||
        candidate.StartsWith(Path.TrimEndingDirectorySeparator(root) + Path.DirectorySeparatorChar, FileSystemComparison);

    private static FileStream CreateOutput(string root, string relative)
    {
        string normalized = relative.Replace('\\', '/');
        string[] parts = normalized.Split('/');
        if (Path.IsPathRooted(normalized) || parts.Any(UnsafeSegment))
            throw new UsageException("Unsafe output path rejected: rooted, traversal, device or invalid path component.");
        string destination = Path.GetFullPath(Path.Combine(root, Path.Combine(parts)));
        if (!Within(destination, root) || string.Equals(destination, root, FileSystemComparison))
            throw new UsageException("Output path escapes the explicit output directory.");

        // Reject existing symlinks/junctions in the entire output ancestry, including dangling links.
        // New files only: never overwrite an existing file, hard link, or source prerequisite.
        var parent = new DirectoryInfo(Path.GetDirectoryName(destination)!);
        var ancestors = new Stack<DirectoryInfo>();
        for (DirectoryInfo? node = parent; node != null; node = node.Parent) ancestors.Push(node);
        while (ancestors.TryPop(out var node))
        {
            if (node.LinkTarget != null || (node.Exists && (node.Attributes & FileAttributes.ReparsePoint) != 0))
                throw new UsageException("Output through a symlink or junction is not permitted.");
            if (!node.Exists) node.Create();
        }
        return new FileStream(destination, FileMode.CreateNew, FileAccess.Write, FileShare.None);
    }

    private static bool UnsafeSegment(string part)
    {
        if (part.Length == 0 || part is "." or ".." || part.EndsWith(' ') || part.EndsWith('.')) return true;
        if (part.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0 || part.Any(c => c < 32 || ":*?\"<>|".Contains(c))) return true;
        string stem = part.Split('.')[0].ToUpperInvariant();
        return stem is "CON" or "PRN" or "AUX" or "NUL" or "CLOCK$" or "CONIN$" or "CONOUT$" ||
            (stem.Length == 4 && (stem.StartsWith("COM", StringComparison.Ordinal) || stem.StartsWith("LPT", StringComparison.Ordinal)) &&
             "123456789¹²³".Contains(stem[3]));
    }

    private sealed class Options
    {
        public required string Command { get; init; }
        public List<string> Paths { get; } = [];
        private readonly Dictionary<string, string> values = new(StringComparer.Ordinal);
        public string? Value(string name) => values.GetValueOrDefault(name);
        public string Required(string name) => Value(name) ?? throw new UsageException("Missing required option: " + name);

        public static Options Parse(string[] args)
        {
            if (args[0] is not ("list" or "export-text" or "export-json"))
                throw new UsageException("Expected list, export-text or export-json. Use --help for usage.");
            var result = new Options { Command = args[0] };
            string[] allowed = ["--paks", "--out", "--game", "--aes-env", "--aes-file", "--key-guid", "--usmap", "--oodle", "--list-file", "--contains", "--path"];
            for (int i = 1; i < args.Length; i += 2)
            {
                string name = args[i];
                if (!allowed.Contains(name, StringComparer.Ordinal) || i + 1 >= args.Length || string.IsNullOrWhiteSpace(args[i + 1]))
                    throw new UsageException("Invalid option or missing value. Use --help; argument values are not echoed.");
                if (name == "--path") result.Paths.Add(args[i + 1]);
                else if (!result.values.TryAdd(name, args[i + 1])) throw new UsageException("Duplicate option. Only --path can be repeated.");
            }
            if (result.Command == "list" && result.Paths.Count != 0)
                throw new UsageException("list does not accept --path. Use --contains to filter listings.");
            if (result.Command != "list" && (result.Paths.Count == 0 || result.Value("--contains") != null || result.Value("--list-file") != null))
                throw new UsageException("Exports require --path and do not accept list-only options.");
            return result;
        }
    }

    private sealed class UsageException(string message) : Exception(message) { }

    private const string Help = """
        NativeAssetReader - read-only indexed paths and explicitly selected native data

        list        --paks DIR --out DIR [--list-file RELATIVE_PATH] [--contains TEXT]
        export-text --paks DIR --out DIR --path ORIGINAL_PATH [--path ORIGINAL_PATH ...]
        export-json --paks DIR --out DIR --usmap FILE --path ORIGINAL_UASSET_OR_UMAP_PATH [...]

        Common optional inputs:
          --game GAME_UE5_7       CUE4Parse EGame enum name (default GAME_UE5_7).
          --aes-env ENV_NAME     Read an operator-provided AES key from this environment variable.
          --aes-file FILE        Alternatively read a UTF-8 file containing only the key.
          --key-guid GUID        AES GUID; default all zeroes. No key discovery or guessing.
          --usmap FILE           Operator-provided matching native mappings.
          --oodle DLL            Operator-provided local Oodle library; never downloaded.

        list writes paths.txt by default, one original indexed path per UTF-8 line.
        --contains filters listing only; exports require exact case-sensitive paths, never globs.
        export-text permits JS/JSON/INI only, preserving bytes and original subdirectories.
        export-json writes ORIGINAL_PATH.json including available Blueprint bytecode.
        Each explicitly selected source file is limited to 32 MiB; no bulk media conversion.
        Only top-level PAK/UTOC archives are scanned. No source files or game saves are modified.
        Output root must not overlap Paks or contain supplied prerequisites. Existing outputs,
        traversal, Windows devices and output symlinks/junctions are rejected; use a fresh directory.
        AES arguments, key values and dependency exception messages are never logged.
        Exit codes: 0 complete; 1 operation/dependency failure; 2 usage/prerequisite failure;
        3 operation completed against a partial mount (some archives remain inaccessible).
        """;
}
