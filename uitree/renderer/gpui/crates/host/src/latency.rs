//! `UITREE_CLICK_BENCH=N`: click latency, for bench/latency/README.md.
//!
//! Once the app has made `main/inc` and `main/n` (the counter), clicks
//! `inc` N times the way the window's own click listener does, a
//! `uit_emit` on the main thread, and times three points for each:
//!
//! - **state**: the pump whose changes include `n`'s `text`;
//! - **render**: the window's next `render` after that;
//! - **frame**: the callback GPUI runs at the start of the frame after it,
//!   which is when the rendered frame has been handed to the display.
//!
//! Hit-testing is skipped on purpose: the native counter
//! (examples/native_counter.rs) skips it the same way, so both start at
//! "the click handler runs".
//!
//! `UITREE_HOST_APP='CMD'` runs CMD on the host with `$UI_DIAL` set to the
//! core's socket, instead of a program in h9: a compiled client that
//! talks 9P itself (bench/latency/counter-go).

use std::rc::Rc;
use std::time::{Duration, Instant};

use gpui::{App, AsyncApp, Window};

use crate::runtime::Inner as Host;

#[derive(Default)]
pub(crate) struct Clicks {
    probe: Option<Probe>,
    /// (state, render, frame) per click, from the click.
    done: Vec<[Duration; 3]>,
}

struct Probe {
    t0: Instant,
    n: uitcore::Node,
    state: Option<Instant>,
    render: Option<Instant>,
    frame: Option<Instant>,
}

/// From apply_changes: did this pump change `n`'s text?
pub(crate) fn on_props(host: &Host, props: &[(uitcore::Node, String)]) {
    let mut c = host.clicks.borrow_mut();
    let Some(p) = c.probe.as_mut() else { return };
    if p.state.is_none() && props.iter().any(|(n, f)| *n == p.n && f == "text") {
        p.state = Some(Instant::now());
    }
}

/// From the window's render.
pub(crate) fn on_render(host: &Rc<Host>, window: &mut Window) {
    {
        let mut c = host.clicks.borrow_mut();
        let Some(p) = c.probe.as_mut() else { return };
        if p.state.is_none() || p.render.is_some() {
            return;
        }
        p.render = Some(Instant::now());
    }
    let h = host.clone();
    window.on_next_frame(move |_, _| {
        if let Some(p) = h.clicks.borrow_mut().probe.as_mut() {
            p.frame.get_or_insert_with(Instant::now);
        }
    });
}

pub(crate) fn start(host: &Rc<Host>, n: usize, cx: &mut App) {
    let h = host.clone();
    cx.spawn(async move |cx: &mut AsyncApp| {
        let wait = Instant::now();
        let (inc, num) = loop {
            let idx = h.index.borrow();
            if let (Some(&a), Some(&b)) = (idx.get("main/inc"), idx.get("main/n")) {
                break (a, b);
            }
            drop(idx);
            if wait.elapsed() > Duration::from_secs(60) {
                eprintln!("clickbench: no main/inc and main/n after 60 s");
                let _ = cx.update(|cx| cx.quit());
                return;
            }
            cx.background_executor().timer(Duration::from_millis(50)).await;
        };
        // Let the first frames settle.
        cx.background_executor().timer(Duration::from_millis(1000)).await;
        for i in 0..n {
            h.clicks.borrow_mut().probe = Some(Probe { t0: Instant::now(), n: num, state: None, render: None, frame: None });
            let _ = cx.update(|_| {
                if let Ok(core) = h.core.try_borrow() {
                    let _ = core.emit(inc, "click", &[]);
                    core.wake();
                }
            });
            let t = Instant::now();
            loop {
                cx.background_executor().timer(Duration::from_micros(200)).await;
                let done = h.clicks.borrow().probe.as_ref().is_some_and(|p| p.frame.is_some());
                if done || t.elapsed() > Duration::from_secs(5) {
                    break;
                }
            }
            let mut c = h.clicks.borrow_mut();
            match c.probe.take() {
                Some(Probe { t0, state: Some(s), render: Some(r), frame: Some(f), .. }) => c.done.push([s - t0, r - t0, f - t0]),
                _ => eprintln!("clickbench: click {i} timed out"),
            }
            drop(c);
            // Off the frame grid, so clicks land at different vsync phases.
            cx.background_executor().timer(Duration::from_millis(97 + (i as u64 * 13) % 17)).await;
        }
        report("built-in renderer", &h.clicks.borrow().done);
        let _ = cx.update(|cx| crate::runtime::quit(&h, cx));
    })
    .detach();
}

/// Prints p50/p90/max of each point, in ms. Shared with the native
/// counter, whose rows have the same shape.
pub fn report(what: &str, rows: &[[Duration; 3]]) {
    let col = |k: usize| {
        let mut v: Vec<f64> = rows.iter().map(|r| r[k].as_secs_f64() * 1e3).collect();
        v.sort_by(|a, b| a.partial_cmp(b).unwrap());
        if v.is_empty() {
            return "-".to_string();
        }
        let q = |f: f64| v[((v.len() - 1) as f64 * f) as usize];
        format!("p50 {:7.3}  p90 {:7.3}  max {:7.3}", q(0.5), q(0.9), q(1.0))
    };
    println!("clickbench: {what}, {} clicks, ms from the click handler", rows.len());
    println!("  state  (new text in the renderer's hands)  {}", col(0));
    println!("  render (window render starts)             {}", col(1));
    println!("  frame  (next frame begins: previous shown) {}", col(2));
}
