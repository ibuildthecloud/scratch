//! W4: wire host (or headless), 9P server and h9 machine; map the client's
//! exit string to an exit code.
//!
//! The pieces (DESIGN § Running a client in h9):
//!
//! - a backend: the GPUI host's, or `HeadlessBackend` with `--headless`,
//!   wrapped in [`Guard`], which makes every access after the app quits
//!   fail with `app gone`;
//! - a 9P server on one end of a socket pair, whose other end the machine
//!   mounts on `/mnt/ui`, and one more per connection to `-a addr`;
//! - the machine, on its own thread, running `cmd`.
//!
//! When the client exits, uitreefs exits with 0 for an empty exit string and
//! 1 otherwise, unless `-k`. When the app quits, blocked `events` reads end
//! and later access fails with `app gone` at once; a client still running
//! [`GRACE`] later gets a hangup, and h9 tears the machine down 2 seconds
//! after that. A client that exits on its own in that time gives uitreefs its
//! exit code as usual; one ended by the hangup exits 0, since the app quit.

use std::os::fd::{AsRawFd, OwnedFd};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

use ninep::FsBackend;
use proto::{Error, ErrorKind};

use crate::cli::Args;

/// Where the machine mounts the tree.
pub const MOUNT: &str = "/mnt/ui";
/// How long the machine has after a hangup before h9 tears it down, plus
/// slack for the teardown itself.
const TEARDOWN: Duration = Duration::from_millis(2500);
/// How long a client has to exit by itself after the app quits.
pub const GRACE: Duration = Duration::from_millis(500);

/// Returns the process exit code.
pub fn run(args: Args) -> i32 {
    if args.headless {
        return headless(args);
    }
    gui(args)
}

/// What every part of the lifecycle shares.
pub struct App {
    gone: AtomicBool,
    /// The client is running.
    running: AtomicBool,
    /// It got a hangup because the app quit.
    hung_up: AtomicBool,
    signals: Mutex<h9sys::Signals>,
    quit_tx: Mutex<Option<mpsc::Sender<Event>>>,
    /// The exit code once the client ended.
    done: Mutex<Option<i32>>,
    done_cv: Condvar,
}

/// What the main thread waits for.
enum Event {
    /// The client's run ended.
    Client(Result<h9sys::Status, String>),
    /// The app quit (headless: `quit` on the root ctl).
    Quit,
}

impl App {
    fn new(tx: mpsc::Sender<Event>) -> Arc<App> {
        Arc::new(App {
            gone: AtomicBool::new(false),
            running: AtomicBool::new(false),
            hung_up: AtomicBool::new(false),
            signals: Mutex::new(h9sys::Signals::none()),
            quit_tx: Mutex::new(Some(tx)),
            done: Mutex::new(None),
            done_cv: Condvar::new(),
        })
    }

    pub fn is_gone(&self) -> bool {
        self.gone.load(Ordering::Acquire)
    }

    /// The app quit: later access fails with `app gone`, and a client
    /// still running after [`GRACE`] gets a hangup. Idempotent.
    pub fn quit(self: &Arc<Self>) {
        if self.gone.swap(true, Ordering::AcqRel) {
            return;
        }
        if let Some(tx) = self.quit_tx.lock().unwrap().take() {
            let _ = tx.send(Event::Quit);
        }
        let app = self.clone();
        std::thread::spawn(move || {
            std::thread::sleep(GRACE);
            app.hangup_if_running();
        });
    }

    fn hangup_if_running(&self) {
        if self.running.load(Ordering::Acquire) {
            self.hung_up.store(true, Ordering::Release);
            self.signals.lock().unwrap().hangup();
        }
    }

    /// Records how the client's run ended and returns uitreefs's exit code.
    fn client_ended(&self, r: &Result<h9sys::Status, String>) -> i32 {
        self.running.store(false, Ordering::Release);
        let code = if self.hung_up.load(Ordering::Acquire) { 0 } else { exit_code(r) };
        *self.done.lock().unwrap() = Some(code);
        self.done_cv.notify_all();
        code
    }

    /// The client's exit code, waiting up to `d` for it to end. 0 when no
    /// client runs.
    #[cfg_attr(not(feature = "gui"), allow(dead_code))]
    fn wait_client(&self, d: Duration) -> i32 {
        let g = self.done.lock().unwrap();
        if g.is_none() && !self.running.load(Ordering::Acquire) {
            return 0;
        }
        let (g, _) = self.done_cv.wait_timeout_while(g, d, |c| c.is_none()).unwrap();
        g.unwrap_or(0)
    }
}

/// The backend every 9P connection sees: the real one until the app quits,
/// `app gone` after.
pub struct Guard {
    inner: Arc<dyn FsBackend>,
    app: Arc<App>,
    /// Headless only: copies new `trace` lines to stderr after each write.
    tracer: Option<Mutex<Tracer>>,
}

impl Guard {
    pub fn new(inner: Arc<dyn FsBackend>, app: Arc<App>, headless: bool) -> Arc<Guard> {
        let tracer = headless.then(|| Mutex::new(Tracer::default()));
        Arc::new(Guard { inner, app, tracer })
    }

    /// Prints the `trace` lines that are new since the last call.
    pub fn flush_trace(&self) {
        let Some(t) = &self.tracer else { return };
        let mut t = t.lock().unwrap();
        if t.sub.is_none() {
            t.sub = self.inner.subscribe(&tree::FsPath::new("trace")).ok();
        }
        let Some(sub) = t.sub.as_mut() else { return };
        use std::io::Write;
        let mut err = std::io::stderr().lock();
        while let Some(Ok(b)) = sub.try_read(64 * 1024) {
            if b.is_empty() {
                break;
            }
            let _ = err.write_all(&b);
        }
    }
}

/// Headless: a subscription to the `trace` stream, opened on first use.
#[derive(Default)]
pub struct Tracer {
    sub: Option<tree::Subscription>,
}

fn gone() -> Error {
    Error::new(ErrorKind::AppGone, "")
}

#[async_trait::async_trait]
impl FsBackend for Guard {
    fn snapshot(&self) -> Arc<tree::Snapshot> {
        self.inner.snapshot()
    }
    async fn apply(&self, s: tree::SessionId, op: tree::Op) -> Result<(), Error> {
        let closing = matches!(op, tree::Op::SessionClosed);
        if self.app.is_gone() && !closing {
            return Err(gone());
        }
        // A failed op is in the trace too (as an `error` line), so an
        // error at clunk, which rc ignores, still shows on stderr.
        let r = self.inner.apply(s, op).await;
        self.flush_trace();
        r
    }
    fn subscribe(&self, events_file: &tree::FsPath) -> Result<tree::Subscription, Error> {
        if self.app.is_gone() {
            return Err(gone());
        }
        self.inner.subscribe(events_file)
    }
    fn new_session(&self) -> tree::SessionId {
        self.inner.new_session()
    }
    fn extra_stat(&self, p: &tree::FsPath) -> Option<tree::Stat> {
        self.inner.extra_stat(p)
    }
    fn extra_readdir(&self, p: &tree::FsPath) -> Vec<tree::Stat> {
        self.inner.extra_readdir(p)
    }
    fn extra_read(&self, p: &tree::FsPath) -> Option<bytes::Bytes> {
        self.inner.extra_read(p)
    }
    fn is_gone(&self) -> bool {
        self.app.is_gone() || self.inner.is_gone()
    }
}

/// The exit code for how the client's run ended, saying why on stderr
/// when it isn't a plain success.
pub fn exit_code(r: &Result<h9sys::Status, String>) -> i32 {
    match r {
        Ok(h9sys::Status::Exited(s)) if s.is_empty() => 0,
        Ok(h9sys::Status::Exited(s)) => {
            eprintln!("uitreefs: client exited: {s}");
            1
        }
        Ok(h9sys::Status::Killed(note)) => {
            eprintln!("uitreefs: client killed: {note}");
            1
        }
        Err(e) => {
            eprintln!("uitreefs: {e}");
            1
        }
    }
}

/// Serves one connection on its own thread until it closes.
fn serve_stream(stream: UnixStream, backend: Arc<dyn FsBackend>) {
    std::thread::Builder::new()
        .name("uitreefs-9p".into())
        .spawn(move || {
            let io = match smol::Async::new(stream) {
                Ok(io) => io,
                Err(e) => return eprintln!("uitreefs: 9p: {e}"),
            };
            if let Err(e) = smol::block_on(ninep::serve(io, backend)) {
                eprintln!("uitreefs: 9p: {e}");
            }
        })
        .expect("spawning the 9P thread");
}

/// `-a addr`: serves it on a thread, each connection its own session.
/// Returns the unix socket's path, to remove at exit.
fn listen(addr: &str, insecure: bool, backend: Arc<dyn FsBackend>) -> Result<Option<PathBuf>, String> {
    let a = ninep::transport::parse_addr(addr)?;
    let sock = match &a {
        ninep::transport::Addr::Unix(p) => Some(p.clone()),
        _ => None,
    };
    // Bind before returning, so a bad address fails uitreefs at once.
    let listener = match &sock {
        Some(p) => Some(ninep::transport::bind_unix(p).map_err(|e| format!("{addr}: {e}"))?),
        None => None,
    };
    let addr = addr.to_string();
    std::thread::Builder::new()
        .name("uitreefs-listen".into())
        .spawn(move || {
            let r = smol::block_on(async {
                match listener {
                    Some(l) => loop {
                        let (s, _) = l.accept().await?;
                        let b = backend.clone();
                        smol::spawn(async move {
                            let _ = ninep::serve(s, b).await;
                        })
                        .detach();
                    },
                    None => ninep::transport::listen_and_serve(&a, insecure, backend).await,
                }
            });
            if let Err(e) = r {
                eprintln!("uitreefs: -a {addr}: {e}");
            }
        })
        .map_err(|e| e.to_string())?;
    Ok(sock)
}

/// The machine's config for `args`, with `guest` as its end of the pair.
fn machine_config(args: &Args, guest: OwnedFd) -> Result<h9sys::Config, String> {
    let cwd = std::env::current_dir().and_then(std::fs::canonicalize).map_err(|e| format!("cwd: {e}"))?;
    let mut env = vec![format!("ui={MOUNT}")];
    env.extend(args.env.iter().cloned());
    // With a Linux root, `/mnt/ui` is there in the Linux view too, so
    // Linux clients use `$ui` as is (DESIGN § Running a client in h9).
    let mut dirs = args.dirs.clone();
    if dirs.iter().any(|d| d.contains(":#L")) {
        dirs.push(format!("{}:#L/mnt:a", linux_mnt()?));
    }
    Ok(h9sys::Config {
        // As in h9: --root, else $H9ROOT, else the built-in root.
        root: args.root.clone().or_else(|| std::env::var("H9ROOT").ok().filter(|r| !r.is_empty())).unwrap_or_else(|| "builtin".into()),
        cwd,
        dirs,
        ninep_fd: guest,
        ninep_dst: MOUNT.into(),
        env,
        out_fd: std::io::stdout().as_raw_fd(),
        err_fd: std::io::stderr().as_raw_fd(),
        profile: String::new(),
        policy_flags: args.policy_flags.clone(),
    })
}

/// A host directory holding `ui -> /9/mnt/ui`, mounted after `#L/mnt`, so
/// the Linux view has `/mnt/ui` beside `/mnt/term`.
fn linux_mnt() -> Result<String, String> {
    let dir = std::env::temp_dir().join(format!("uitreefs-mnt-{}", std::process::id()));
    let _ = std::fs::create_dir_all(&dir);
    let link = dir.join("ui");
    if std::fs::symlink_metadata(&link).is_err() {
        std::os::unix::fs::symlink("/9/mnt/ui", &link).map_err(|e| format!("{}: {e}", link.display()))?;
    }
    Ok(dir.display().to_string())
}

/// Starts the client: a socket pair served by `backend`, and the machine on
/// its own thread. The run's result goes to `tx`. Fails before anything
/// runs if the machine can't be configured.
fn start_client(args: &Args, backend: Arc<dyn FsBackend>, app: &Arc<App>, tx: mpsc::Sender<Event>) -> Result<(), String> {
    let (host_end, guest_end) = UnixStream::pair().map_err(|e| format!("socketpair: {e}"))?;
    let cfg = machine_config(args, OwnedFd::from(guest_end))?;
    serve_stream(host_end, backend);
    let (prog, argv) = (args.cmd[0].clone(), args.cmd.clone());
    app.running.store(true, Ordering::Release);
    // The machine is !Send: it's made, run and dropped on its thread, and
    // only its signals come back.
    let (sig_tx, sig_rx) = mpsc::channel();
    std::thread::Builder::new()
        .name("uitreefs-h9".into())
        .spawn(move || {
            let mut m = match h9sys::Machine::new(cfg) {
                Ok(m) => m,
                Err(e) => {
                    let _ = sig_tx.send(Err(e));
                    return;
                }
            };
            let _ = sig_tx.send(Ok(m.signals()));
            let r = m.run(&prog, &argv);
            drop(m);
            let _ = tx.send(Event::Client(r));
        })
        .map_err(|e| e.to_string())?;
    let signals = match sig_rx.recv() {
        Ok(Ok(s)) => s,
        Ok(Err(e)) => {
            app.running.store(false, Ordering::Release);
            return Err(e);
        }
        Err(_) => {
            app.running.store(false, Ordering::Release);
            return Err("h9 thread died".into());
        }
    };
    *app.signals.lock().unwrap() = signals;
    Ok(())
}

/// `--headless`: the tree with no window, its trace on stderr.
fn headless(args: Args) -> i32 {
    let (tx, rx) = mpsc::channel();
    let app = App::new(tx.clone());
    let hb = ninep::HeadlessBackend::new(tree::Registry::from_catalog());
    // The tree quits the app (`quit` on the root ctl, or a quit request's
    // answer); headless has no host to tell, so it watches.
    {
        let (hb, app) = (hb.clone(), app.clone());
        std::thread::spawn(move || {
            smol::block_on(hb.wait_gone());
            app.quit();
        });
    }
    let inner: Arc<dyn FsBackend> = hb;
    let guard = Guard::new(inner, app.clone(), true);
    let backend: Arc<dyn FsBackend> = guard.clone();

    let sock = match args.addr.as_deref().map(|a| listen(a, args.insecure, backend.clone())).transpose() {
        Ok(s) => s.flatten(),
        Err(e) => {
            eprintln!("uitreefs: -a {e}");
            return 1;
        }
    };
    let cleanup = || {
        if let Some(p) = &sock {
            let _ = std::fs::remove_file(p);
        }
    };
    if !args.cmd.is_empty() {
        if let Err(e) = start_client(&args, backend.clone(), &app, tx.clone()) {
            eprintln!("uitreefs: {e}");
            cleanup();
            return 1;
        }
    }
    drop(tx);

    let code = loop {
        match rx.recv() {
            Ok(Event::Client(r)) => {
                let code = app.client_ended(&r);
                if app.is_gone() || !args.keep {
                    break code;
                }
            }
            Ok(Event::Quit) => {
                // The client's own exit, or its hangup and h9's teardown.
                break match rx.recv_timeout(GRACE + TEARDOWN) {
                    Ok(Event::Client(r)) => app.client_ended(&r),
                    _ => 0,
                };
            }
            // -a with no client and no quit yet: the senders live in App.
            Err(_) => break 0,
        }
    };
    // Lines from timeouts after the last write.
    guard.flush_trace();
    cleanup();
    code
}

/// The GPUI app: `host::run` owns the main thread until the app quits.
#[cfg(feature = "gui")]
fn gui(args: Args) -> i32 {
    let (tx, rx) = mpsc::channel();
    let app = App::new(tx.clone());
    let opts = host::HostOptions { title: args.title.clone(), keep: args.keep };
    let sock: Arc<Mutex<Option<PathBuf>>> = Arc::default();
    let started = {
        let (app, args, sock) = (app.clone(), args.clone(), sock.clone());
        move |inner: Arc<dyn FsBackend>| {
            // The host quits the app itself; the guard only shuts the door
            // once it has.
            let backend: Arc<dyn FsBackend> = Guard::new(inner, app.clone(), false);
            if let Some(a) = &args.addr {
                match listen(a, args.insecure, backend.clone()) {
                    Ok(p) => *sock.lock().unwrap() = p,
                    Err(e) => {
                        eprintln!("uitreefs: -a {e}");
                        std::process::exit(1);
                    }
                }
            }
            if args.cmd.is_empty() {
                return;
            }
            if let Err(e) = start_client(&args, backend, &app, tx) {
                eprintln!("uitreefs: {e}");
                std::process::exit(1);
            }
            // The client's exit ends the app unless -k. host::run has no
            // way to be told to quit, so this exits the process from here.
            let keep = args.keep;
            let (app, sock) = (app.clone(), sock.clone());
            std::thread::spawn(move || {
                if let Ok(Event::Client(r)) = rx.recv() {
                    let code = app.client_ended(&r);
                    if app.is_gone() {
                        return;
                    }
                    if !keep {
                        if let Some(p) = sock.lock().unwrap().as_ref() {
                            let _ = std::fs::remove_file(p);
                        }
                        std::process::exit(code);
                    }
                }
            });
        }
    };
    host::run(opts, started);
    // The app quit: the client exits, or gets a hangup and its 2 seconds.
    app.quit();
    let code = app.wait_client(GRACE + TEARDOWN);
    if let Some(p) = sock.lock().unwrap().as_ref() {
        let _ = std::fs::remove_file(p);
    }
    code
}

#[cfg(not(feature = "gui"))]
fn gui(_args: Args) -> i32 {
    eprintln!("uitreefs: built without the GPUI host (feature gui); use --headless");
    2
}

#[cfg(test)]
mod tests {
    use super::*;
    use bytes::Bytes;

    #[test]
    fn exit_codes() {
        assert_eq!(exit_code(&Ok(h9sys::Status::Exited(String::new()))), 0);
        assert_eq!(exit_code(&Ok(h9sys::Status::Exited("rc: oops".into()))), 1);
        assert_eq!(exit_code(&Ok(h9sys::Status::Killed("h9: timeout".into()))), 1);
        assert_eq!(exit_code(&Err("rc: not found".into())), 1);
    }

    #[test]
    fn app_quit_once() {
        let (tx, rx) = mpsc::channel();
        let app = App::new(tx);
        assert!(!app.is_gone());
        app.quit();
        app.quit();
        assert!(app.is_gone());
        assert!(matches!(rx.recv(), Ok(Event::Quit)));
        assert!(rx.recv().is_err());
        assert_eq!(app.wait_client(Duration::ZERO), 0);
    }
}
