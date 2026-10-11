import Foundation

/// The root half of lid-closed mode. Only root can keep an Apple-silicon MacBook awake with its lid closed
/// (`pmset -a disablesleep 1`), so a tiny shell script runs as a LaunchDaemon and does exactly that, and only while the
/// app keeps a fresh lease file. Everything it installs is in this file as plain text, so it can be read before it runs:
/// `script` (the helper), `plist(...)` (its launchd job), `installCommand` and `uninstallCommand`.
///
/// The app never runs anything as root by itself. Installing and removing go through `/usr/bin/osascript ... with
/// administrator privileges`, which asks for the user's password or Touch ID each time, and only when they click.
enum LidHelper {
    static let label = "io.github.avi130805.Monotask.lid"
    static let helperPath = "/Library/PrivilegedHelperTools/io.github.avi130805.Monotask.lid"
    static let plistPath = "/Library/LaunchDaemons/io.github.avi130805.Monotask.lid.plist"
    /// Root-owned and world-readable: the helper's status line and its ownership marker live here.
    static let stateFolder = "/Library/Application Support/Monotask"
    static let statusPath = stateFolder + "/lid-status"
    /// Exists only while the helper itself has turned sleep off.
    static let ownedPath = stateFolder + "/lid-owned"

    /// The lease the app writes (and the helper reads) in the user's data folder.
    static func leaseURL(dataFolder: URL) -> URL {
        dataFolder.appendingPathComponent("lid", isDirectory: true).appendingPathComponent("lease")
    }

    /// A lease runs this long from when it is written…
    static let leaseLifetime: TimeInterval = 60
    /// …and is renewed this often, so a hung or killed app lets the Mac sleep within a minute.
    static let leaseRenewal: TimeInterval = 15
    /// The helper checks in every 5 s; a status older than this means it isn't running.
    static let statusStaleAfter: TimeInterval = 30

    // MARK: The helper

    /// The helper, run by launchd as `/bin/sh <this> <lease path> <uid>`. POSIX sh, absolute command paths, no eval.
    static let script = #"""
#!/bin/sh
# monotask-lid-helper 1
#
# Monotask's lid helper. It keeps this Mac awake with the lid closed ("pmset -a disablesleep 1") only while the
# Monotask app holds a fresh lease, and turns sleep back on as soon as the lease lapses, whenever it starts (after a
# reboot or a crash) and when it is stopped. It never touches a setting it didn't make.
#
# Installed by Monotask as root:wheel 755 at /Library/PrivilegedHelperTools/io.github.avi130805.Monotask.lid and run
# by launchd as: /bin/sh <this file> <lease file> <uid of the user whose lease it honours>
# Source: Sources/Monotask/Core/LidHelper.swift, https://github.com/Avi130805/monotask

PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
umask 022

LEASE="${1:-}"
OWNER="${2:-}"

PMSET=/usr/bin/pmset
IOREG=/usr/sbin/ioreg
STATE='/Library/Application Support/Monotask'
ONCE=""

# Tests only. launchd never sets these (the job has no EnvironmentVariables). It is all three or nothing, and never
# the real pmset, so a test can't reach the real setting.
if [ -n "${MT_PMSET:-}${MT_IOREG:-}${MT_ROOT:-}${MT_ONCE:-}" ]; then
  if [ -z "${MT_PMSET:-}" ] || [ -z "${MT_IOREG:-}" ] || [ -z "${MT_ROOT:-}" ] \
    || [ "$MT_PMSET" = /usr/bin/pmset ] || [ "$MT_ROOT" = / ]; then
    echo "lid helper: tests must set MT_PMSET, MT_IOREG and MT_ROOT to fakes" >&2
    exit 78
  fi
  PMSET="$MT_PMSET"
  IOREG="$MT_IOREG"
  STATE="$MT_ROOT/Library/Application Support/Monotask"
  ONCE="${MT_ONCE:-}"
fi

OWNED="$STATE/lid-owned"      # holds the time we turned sleep off; exists only while we did
CAPPED="$STATE/lid-capped"    # exists after the 8-hour limit, until the lease lapses once
STATUS="$STATE/lid-status"    # one line for the app: alive <epoch> sleepDisabled=<0|1|?> owned=<0|1> reason=<word>
INTERVAL=5
LEASE_AHEAD=120               # a lease may run at most this many seconds ahead
CAP=28800                     # 8 hours awake in a row

/bin/mkdir -p "$STATE" 2>/dev/null

# Digits only, at most 12, no leading zero (sh would read that as octal).
is_number() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    0) return 0 ;;
    0*) return 1 ;;
  esac
  [ "${#1}" -le 12 ]
}

now() {
  /bin/date +%s
}

# bounded <seconds> <command...>: runs the command, killing it if it takes longer. Returns its status.
bounded() {
  b_ticks=$(( $1 * 10 ))
  shift
  "$@" &
  b_pid=$!
  while kill -0 "$b_pid" 2>/dev/null; do
    if [ "$b_ticks" -le 0 ]; then
      kill -9 "$b_pid" 2>/dev/null
      break
    fi
    /bin/sleep 0.1
    b_ticks=$((b_ticks - 1))
  done
  wait "$b_pid"
}

# Prints 1 or 0, the real SleepDisabled setting, or nothing when pmset can't say.
sleep_disabled() {
  bounded 10 "$PMSET" -g 2>/dev/null \
    | /usr/bin/awk '$1 == "SleepDisabled" && ($2 == "0" || $2 == "1") { print $2; exit }'
}

# True when the lid is closed and closing it would normally sleep this Mac (no external display keeping it awake).
lid_closed() {
  l_out="$(bounded 10 "$IOREG" -r -k AppleClamshellState -d 1 2>/dev/null)"
  case "$l_out" in
    *'"AppleClamshellState" = Yes'*) ;;
    *) return 1 ;;
  esac
  case "$l_out" in
    *'"AppleClamshellCausesSleep" = No'*) return 1 ;;
  esac
  return 0
}

# Prints the lease's expiry if the lease is a regular file (not a link) owned by $OWNER holding exactly
# "awake <epoch>". Prints nothing otherwise.
lease_expiry() {
  is_number "$OWNER" || return 1
  case "$LEASE" in
    /*) ;;
    *) return 1 ;;
  esac
  [ -L "$LEASE" ] && return 1
  [ -f "$LEASE" ] || return 1
  [ "$(/usr/bin/stat -f %u "$LEASE" 2>/dev/null)" = "$OWNER" ] || return 1
  e_line="$(bounded 2 /usr/bin/head -c 64 "$LEASE" 2>/dev/null)"
  case "$e_line" in
    "awake "*) ;;
    *) return 1 ;;
  esac
  e_expiry="${e_line#awake }"
  is_number "$e_expiry" || return 1
  printf '%s\n' "$e_expiry"
}

write_status() {
  s_tmp="$STATE/.lid-status.$$"
  if printf '%s %s sleepDisabled=%s owned=%s reason=%s\n' "$1" "$(now)" "$2" "$3" "$4" >"$s_tmp" 2>/dev/null; then
    /bin/chmod 644 "$s_tmp" 2>/dev/null
    /bin/mv -f "$s_tmp" "$STATUS" 2>/dev/null || /bin/rm -f "$s_tmp"
  fi
}

# Turns sleep off. The marker goes first: a crash in between leaves a harmless marker, never an unmarked setting.
disable_sleep() {
  printf '%s\n' "$(now)" >"$OWNED.tmp" 2>/dev/null && /bin/mv -f "$OWNED.tmp" "$OWNED" || return 1
  bounded 10 "$PMSET" -a disablesleep 1 >/dev/null 2>&1
}

# Turns sleep back on if we turned it off. True once it is no longer ours.
restore_sleep() {
  [ -e "$OWNED" ] || return 0
  if bounded 10 "$PMSET" -a disablesleep 0 >/dev/null 2>&1; then
    /bin/rm -f "$OWNED"
    return 0
  fi
  return 1
}

step() {
  t="$(now)"
  current="$(sleep_disabled)"
  owned=0
  [ -e "$OWNED" ] && owned=1

  want=0
  reason=idle
  expiry="$(lease_expiry)"
  if [ -n "$expiry" ]; then
    if [ "$expiry" -le "$t" ]; then
      reason=expired
    elif [ "$expiry" -gt $((t + LEASE_AHEAD)) ]; then
      reason=ttl
    else
      want=1
      reason=lease
    fi
  elif [ -e "$LEASE" ] || [ -L "$LEASE" ]; then
    reason=invalid
  fi

  # Eight hours awake in a row: stop honouring leases until one lapses.
  if [ "$want" = 1 ]; then
    if [ -e "$CAPPED" ]; then
      want=0
      reason=cap
    elif [ "$owned" = 1 ]; then
      since="$(/usr/bin/head -c 16 "$OWNED" 2>/dev/null)"
      if is_number "$since" && [ $((t - since)) -ge "$CAP" ]; then
        : >"$CAPPED"
        want=0
        reason=cap
      fi
    fi
  else
    /bin/rm -f "$CAPPED"
  fi

  if [ "$want" = 1 ]; then
    if [ "$current" = 1 ]; then
      # Already off. If we didn't do it, it isn't ours to undo later either.
      [ "$owned" = 1 ] || reason=foreign
    elif [ "$current" = 0 ] && disable_sleep; then
      current=1
      owned=1
    else
      # Including when pmset can't say: never risk taking over a setting someone else made.
      reason=error
      [ -e "$OWNED" ] && owned=1
    fi
  elif [ "$owned" = 1 ]; then
    if [ "$current" = 0 ]; then
      # Someone turned sleep back on already; there's nothing of ours left to undo.
      /bin/rm -f "$OWNED"
      owned=0
    elif restore_sleep; then
      current=0
      owned=0
      if lid_closed; then
        bounded 10 "$PMSET" sleepnow >/dev/null 2>&1
      fi
    else
      reason=error
    fi
  fi

  write_status alive "${current:-?}" "$owned" "$reason"
}

on_signal() {
  restore_sleep
  o=0
  [ -e "$OWNED" ] && o=1
  write_status stopped "?" "$o" term
  exit 0
}

trap on_signal TERM INT HUP

# Tests: MT_ONCE=boot runs the start-up clear alone; MT_ONCE=1 runs one check without it.
if [ "$ONCE" != 1 ]; then
  # Whatever came before (a reboot, a crash, kill -9), a setting we left behind goes first.
  restore_sleep
fi
if [ "$ONCE" = boot ]; then
  exit 0
fi

while :; do
  step
  if [ "$ONCE" = 1 ]; then
    exit 0
  fi
  /bin/sleep "$INTERVAL" &
  wait $!
done
"""#

    // MARK: The launchd job

    /// The LaunchDaemon. No EnvironmentVariables, so the helper's test switches can never be set.
    static func plist(leasePath: String, uid: uid_t) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>Label</key>
        \t<string>\(label)</string>
        \t<key>ProgramArguments</key>
        \t<array>
        \t\t<string>/bin/sh</string>
        \t\t<string>\(helperPath)</string>
        \t\t<string>\(xmlEscaped(leasePath))</string>
        \t\t<string>\(uid)</string>
        \t</array>
        \t<key>RunAtLoad</key>
        \t<true/>
        \t<key>KeepAlive</key>
        \t<true/>
        </dict>
        </plist>

        """
    }

    static func xmlEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    // MARK: Install and remove

    /// Where the installer puts each file together before moving it into place, so a running helper's script is never
    /// rewritten under it. Both in the root-only PrivilegedHelperTools folder.
    static let helperStaging = helperPath + ".new"
    static let plistStaging = "/Library/PrivilegedHelperTools/.\(label).plist.new"

    /// What runs as root to install. The two files are carried as base64 and decoded into root-owned folders, so
    /// nothing from a user-writable place is ever run as root. Single quotes only, so it drops into AppleScript as is.
    static func installScript(leasePath: String, uid: uid_t) -> String {
        let helper = Data(script.utf8).base64EncodedString()
        let job = Data(plist(leasePath: leasePath, uid: uid).utf8).base64EncodedString()
        return """
        set -e
        umask 022
        /bin/launchctl bootout system/\(label) 2>/dev/null || true
        /bin/mkdir -p /Library/PrivilegedHelperTools /Library/LaunchDaemons '\(stateFolder)'
        /usr/sbin/chown root:wheel '\(stateFolder)'
        /bin/chmod 755 '\(stateFolder)'
        /bin/echo \(helper) | /usr/bin/base64 -D > \(helperStaging)
        /usr/sbin/chown root:wheel \(helperStaging)
        /bin/chmod 755 \(helperStaging)
        /bin/mv -f \(helperStaging) \(helperPath)
        /bin/echo \(job) | /usr/bin/base64 -D > \(plistStaging)
        /usr/sbin/chown root:wheel \(plistStaging)
        /bin/chmod 644 \(plistStaging)
        /bin/mv -f \(plistStaging) \(plistPath)
        /bin/launchctl bootstrap system \(plistPath)
        """
    }

    /// What runs as root to remove it all. Stopping the job makes the helper turn sleep back on; the marker check
    /// catches a helper that was already gone.
    static let uninstallScript = """
    /bin/launchctl bootout system/\(label) 2>/dev/null || true
    /bin/rm -f \(plistPath) \(helperPath) \(helperStaging) \(plistStaging)
    if [ -e '\(ownedPath)' ]; then /usr/bin/pmset -a disablesleep 0; fi
    /bin/rm -f '\(stateFolder)/'lid-* '\(stateFolder)/'.lid-*
    /bin/rmdir '\(stateFolder)' 2>/dev/null || true
    """

    static let installPrompt = "Monotask wants to install its lid helper, which keeps your Mac awake with the lid closed while coding agents work."
    static let uninstallPrompt = "Monotask wants to remove its lid helper and let your Mac sleep as usual."

    /// The osascript arguments for running `shell` as root, with macOS's own password or Touch ID prompt.
    static func osascriptArguments(shell: String, prompt: String) -> [String] {
        ["-e", "do shell script \"\(appleScriptEscaped(shell))\" with administrator privileges with prompt \"\(appleScriptEscaped(prompt))\""]
    }

    static var installArguments: [String] {
        osascriptArguments(shell: installScript(leasePath: defaultLeasePath, uid: getuid()), prompt: installPrompt)
    }

    static var uninstallArguments: [String] {
        osascriptArguments(shell: uninstallScript, prompt: uninstallPrompt)
    }

    static var defaultLeasePath: String { leaseURL(dataFolder: Store.defaultFileURL.deletingLastPathComponent()).path }

    /// An AppleScript string literal's contents: backslashes, quotes and line breaks escaped.
    static func appleScriptEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    enum RunResult: Equatable {
        case done
        case cancelled
        case failed(String)
    }

    /// Runs osascript with `arguments` and waits. Call it off the main thread: the password prompt waits for the user.
    static func runAsAdmin(_ arguments: [String]) -> RunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        do { try process.run() } catch { return .failed(error.localizedDescription) }
        let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        if process.terminationStatus == 0 { return .done }
        // -128 is "User canceled."
        if message.contains("-128") { return .cancelled }
        return .failed(message.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: What's on disk

    enum Installed: Equatable {
        case missing
        /// Installed, and the same as this build's text.
        case current
        /// Installed from another version of Monotask; installing again updates it.
        case outdated
    }

    static func installed(leasePath: String = defaultLeasePath, uid: uid_t = getuid()) -> Installed {
        let files = FileManager.default
        guard files.fileExists(atPath: helperPath), files.fileExists(atPath: plistPath) else { return .missing }
        let helper = try? String(contentsOfFile: helperPath, encoding: .utf8)
        let job = try? String(contentsOfFile: plistPath, encoding: .utf8)
        return helper == script && job == plist(leasePath: leasePath, uid: uid) ? .current : .outdated
    }

    /// The helper's last status line.
    struct Status: Equatable {
        var alive: Bool
        var at: Date
        var sleepDisabled: Bool?
        var owned: Bool
        var reason: String
    }

    /// `alive|stopped <epoch> sleepDisabled=<0|1|?> owned=<0|1> reason=<word>`; nil for anything else.
    static func parseStatus(_ text: String) -> Status? {
        var line = Substring(text)
        if line.hasSuffix("\n") { line = line.dropLast() }
        let fields = line.split(separator: " ", omittingEmptySubsequences: false)
        guard fields.count == 5, fields[0] == "alive" || fields[0] == "stopped",
              fields[1].count <= 12, fields[1].allSatisfy({ ("0"..."9").contains($0) }), let epoch = Int(fields[1]),
              fields[2].hasPrefix("sleepDisabled="), fields[3].hasPrefix("owned="), fields[4].hasPrefix("reason=") else { return nil }
        let disabled = fields[2].dropFirst("sleepDisabled=".count)
        let owned = fields[3].dropFirst("owned=".count)
        let reason = fields[4].dropFirst("reason=".count)
        guard ["0", "1", "?"].contains(disabled), owned == "0" || owned == "1",
              !reason.isEmpty, reason.allSatisfy({ ("a"..."z").contains($0) }) else { return nil }
        return Status(alive: fields[0] == "alive", at: Date(timeIntervalSince1970: TimeInterval(epoch)),
                      sleepDisabled: disabled == "?" ? nil : disabled == "1", owned: owned == "1", reason: String(reason))
    }

    static func readStatus(at path: String = statusPath) -> Status? {
        guard let data = FileManager.default.contents(atPath: path), data.count <= 256,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return parseStatus(text)
    }

    /// Running and checked in within the last 30 s.
    static func isFresh(_ status: Status?, now: Date) -> Bool {
        guard let status, status.alive else { return false }
        let age = now.timeIntervalSince(status.at)
        return age >= -statusStaleAfter && age <= statusStaleAfter
    }

    /// The lease's whole text.
    static func leaseText(expiry: Date) -> String {
        "awake \(Int(expiry.timeIntervalSince1970))\n"
    }
}
