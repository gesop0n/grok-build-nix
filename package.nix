{
  lib,
  stdenv,
  fetchurl,
  zstd,
  makeWrapper,
  installShellFiles,

  # Upstream release metadata. Overridable so downstream can pin a different
  # version without editing this file:
  #   grok.override { sources = lib.importJSON ./my-sources.json; }
  sources ? lib.importJSON ./sources.json,

  # Shell completions are produced by running the freshly unpacked binary, so
  # they are only available when the build platform can execute the host one.
  installShellCompletions ? stdenv.buildPlatform.canExecute stdenv.hostPlatform,

  # The Nix store is read-only, so the built-in updater can never succeed.
  # Disabled by default; `grok update` still reports what is available.
  disableAutoUpdater ? true,

  # Upstream's installer also links the binary as `agent`. Off by default here
  # because `agent` is a generic name that collides easily on PATH.
  withAgentAlias ? false,
}:

let
  inherit (sources) version channel;

  supportedSystems = lib.attrNames sources.platforms;

  platform =
    sources.platforms.${stdenv.hostPlatform.system} or (throw ''
      grok: unsupported system '${stdenv.hostPlatform.system}'.
      Supported systems: ${lib.concatStringsSep ", " supportedSystems}
    '');

  # x.ai is the documented endpoint; the GCS bucket is the origin it fronts and
  # serves as a mirror when Cloudflare is unreachable.
  src = fetchurl {
    urls = [
      "https://x.ai/cli/grok-${version}-${platform.artifact}.zst"
      "https://storage.googleapis.com/grok-build-public-artifacts/cli/grok-${version}-${platform.artifact}.zst"
    ];
    inherit (platform) hash;
  };
in
stdenv.mkDerivation {
  pname = "grok";
  inherit version src;

  dontUnpack = true;

  # Upstream ships a static-pie ELF on Linux and a signed Mach-O on Darwin.
  # Both are broken by the default fixup phase, which would rewrite the
  # interpreter or strip the code signature.
  dontPatchELF = true;
  dontStrip = true;

  nativeBuildInputs = [
    zstd
    makeWrapper
  ]
  ++ lib.optional installShellCompletions installShellFiles;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin $out/libexec

    # Keep the real executable's basename as `grok`: it re-execs itself when
    # switching screen modes and resolves paths relative to current_exe().
    zstd -q -d $src -o $out/libexec/grok
    chmod +x $out/libexec/grok

    makeWrapper $out/libexec/grok $out/bin/grok \
      ${lib.optionalString disableAutoUpdater "--set GROK_DISABLE_AUTOUPDATER 1"}

    ${lib.optionalString withAgentAlias "ln -s grok $out/bin/agent"}

    runHook postInstall
  '';

  postInstall = lib.optionalString installShellCompletions ''
    # The binary writes into $HOME on startup; keep that inside the sandbox.
    export HOME="$TMPDIR"

    # Generated into files rather than process substitutions: a failing
    # `grok completions` would otherwise install a silently empty completion.
    $out/bin/grok completions bash > grok.bash
    $out/bin/grok completions zsh > _grok
    $out/bin/grok completions fish > grok.fish

    for f in grok.bash _grok grok.fish; do
      if [ ! -s "$f" ]; then
        echo "error: generated completion $f is empty" >&2
        exit 1
      fi
    done

    installShellCompletion --cmd grok \
      --bash grok.bash \
      --zsh _grok \
      --fish grok.fish
  '';

  doInstallCheck = stdenv.buildPlatform.canExecute stdenv.hostPlatform;

  installCheckPhase = ''
    runHook preInstallCheck

    export HOME="$TMPDIR"
    # -w so a pinned "1.0.3" is not satisfied by a binary reporting "1.0.34".
    $out/bin/grok --version | grep -Fw "${version}"

    runHook postInstallCheck
  '';

  passthru = {
    inherit channel sources;
    inherit (sources) platforms;
  };

  meta = {
    description = "Grok Build - xAI's coding agent harness and TUI for the terminal";
    longDescription = ''
      Grok Build is xAI's terminal coding agent: a fullscreen, mouse-interactive
      TUI that reads and edits code, runs commands, and supports AGENTS.md,
      skills, hooks, subagents, MCP servers, and git worktrees.

      This package installs the official prebuilt release binary published at
      https://x.ai/cli (channel: ${channel}).
    '';
    homepage = "https://github.com/xai-org/grok-build";
    downloadPage = "https://x.ai/cli";
    changelog = "https://github.com/xai-org/grok-build/releases";
    license = lib.licenses.asl20;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = supportedSystems;
    mainProgram = "grok";
  };
}
