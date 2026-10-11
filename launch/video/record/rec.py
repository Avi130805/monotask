#!/usr/bin/env python3
"""Record a real terminal session to asciicast v2, driving it with a small script.

The program runs in a real pty; every byte it writes is recorded with its timestamp. The
script only types keys (at human speed) and waits for text to appear on the screen model.
Nothing in the output is edited.

  rec.py <script.json> <out.cast>

script.json: {"cols":110,"rows":30,"cmd":[...],"cwd":...,"env":{...},"steps":[...]}
steps: {"type":"text"} | {"key":"enter"|"down"|"esc"|"tab"} | {"wait":"regex","timeout":s}
       | {"sleep":s} | {"idle":s,"timeout":s}  (wait until output has been quiet for s)
       | {"mark":"name"}  (writes a marker event "m" into the cast)
"""
import json, os, pty, re, select, signal, struct, sys, time, fcntl, termios
import pyte

KEYS = {"enter": "\r", "down": "\x1b[B", "up": "\x1b[A", "esc": "\x1b", "tab": "\t",
        "ctrl-c": "\x03", "ctrl-d": "\x04", "space": " ", "backspace": "\x7f"}

def main():
    spec = json.load(open(sys.argv[1]))
    out_path = sys.argv[2]
    cols, rows = spec.get("cols", 110), spec.get("rows", 30)
    cps = spec.get("char_ms", 55) / 1000.0
    screen = pyte.Screen(cols, rows)
    stream = pyte.ByteStream(screen)

    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(spec["cwd"])
        os.execvpe(spec["cmd"][0], spec["cmd"], spec["env"])
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))

    t0 = time.monotonic()
    events = []
    last_out = [time.monotonic()]
    log = open(out_path + ".log", "w")

    def pump(timeout):
        r, _, _ = select.select([fd], [], [], timeout)
        if fd in r:
            try:
                data = os.read(fd, 65536)
            except OSError:
                return False
            if not data:
                return False
            events.append([round(time.monotonic() - t0, 6), "o", data.decode("utf-8", "replace")])
            stream.feed(data)
            last_out[0] = time.monotonic()
        return True

    def screen_text():
        return "\n".join(screen.display)

    def run_for(seconds):
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            if not pump(min(0.02, max(0, end - time.monotonic()))):
                return False
        return True

    def send(s):
        os.write(fd, s.encode())
        events.append([round(time.monotonic() - t0, 6), "i", s])

    alive = True
    for i, step in enumerate(spec["steps"]):
        log.write(f"{time.monotonic()-t0:8.2f} step {i}: {json.dumps(step)}\n"); log.flush()
        if "type" in step:
            for ch in step["type"]:
                send(ch)
                run_for(cps)
        elif "key" in step:
            send(KEYS[step["key"]])
            run_for(step.get("after", 0.05))
        elif "sleep" in step:
            run_for(step["sleep"])
        elif "mark" in step:
            events.append([round(time.monotonic() - t0, 6), "m", step["mark"]])
        elif "wait" in step:
            rx = re.compile(step["wait"], re.S)
            end = time.monotonic() + step.get("timeout", 60)
            while not rx.search(screen_text()):
                if time.monotonic() > end:
                    log.write(f"TIMEOUT waiting for {step['wait']!r}\n--- screen ---\n{screen_text()}\n")
                    if step.get("optional"):
                        break
                    finish(events, spec, out_path, fd, pid, log, ok=False)
                    return 2
                if not pump(0.05):
                    break
        elif "idle" in step:
            end = time.monotonic() + step.get("timeout", 120)
            while time.monotonic() - last_out[0] < step["idle"] and time.monotonic() < end:
                pump(0.05)
        elif "turn" in step:
            # Let the agent work. Approve permission prompts on camera (after a visible pause);
            # finish when the input box is back and output has been quiet for a while.
            cfg = step["turn"]
            end = time.monotonic() + cfg.get("timeout", 300)
            approved = 0
            while time.monotonic() < end:
                pump(0.05)
                txt = screen_text()
                if re.search(r"Do you want to (proceed|make this edit|create)", txt) and time.monotonic() - last_out[0] > 0.3:
                    log.write("--- permission prompt ---\n" + txt + "\n")
                    run_for(cfg.get("approve_delay", 1.6))
                    events.append([round(time.monotonic() - t0, 6), "m", "approve"])
                    send("\r")
                    approved += 1
                    run_for(0.5)
                    continue
                busy = re.search(r"esc to interrupt", txt)
                if not busy and re.search(cfg.get("ready", r"\? for shortcuts"), txt) \
                        and time.monotonic() - last_out[0] > cfg.get("quiet", 3.0):
                    break
            log.write(f"turn done approved={approved}\n--- screen ---\n{screen_text()}\n")
        elif "screen" in step:
            log.write("--- screen ---\n" + screen_text() + "\n")
    finish(events, spec, out_path, fd, pid, log, ok=True)
    return 0

def finish(events, spec, out_path, fd, pid, log, ok):
    log.write(f"--- final ok={ok} ---\n")
    try:
        os.kill(pid, signal.SIGHUP)
    except ProcessLookupError:
        pass
    header = {"version": 2, "width": spec.get("cols", 110), "height": spec.get("rows", 30),
              "timestamp": int(time.time()), "title": spec.get("title", ""),
              "env": {"TERM": spec["env"].get("TERM", "xterm-256color"), "SHELL": "/bin/zsh"}}
    with open(out_path, "w") as f:
        f.write(json.dumps(header) + "\n")
        for e in events:
            f.write(json.dumps(e, ensure_ascii=False) + "\n")
    log.close()

if __name__ == "__main__":
    sys.exit(main())
