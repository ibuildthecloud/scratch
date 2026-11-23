//! The counter as a plain GPUI app, with no uitree: the baseline for
//! bench/latency/README.md.
//!
//!     cargo run --release -p host --example native_counter [-- N]
//!
//! Draws the same counter (−, the number, +) and clicks `+` N times
//! (default 200) by calling its click handler, the same code GPUI's
//! `on_click` runs after hit-testing, then times, from the click:
//!
//! - **state**: the handler has updated the count (it is synchronous);
//! - **render**: the view's next `render`;
//! - **frame**: the start of the frame after it (the rendered frame was
//!   handed to the display), from `Window::on_next_frame`.
//!
//! The same three points as UITREE_CLICK_BENCH in the uitree host.

use std::cell::RefCell;
use std::rc::Rc;
use std::time::{Duration, Instant};

use gpui::{
    div, prelude::*, px, rgb, size, App, AsyncApp, Bounds, Context, Entity, IntoElement, Render, Window, WindowBounds, WindowOptions,
};

#[derive(Default)]
struct Probe {
    t0: Option<Instant>,
    state: Option<Instant>,
    render: Option<Instant>,
    frame: Option<Instant>,
}

struct Counter {
    n: i32,
    probe: Rc<RefCell<Probe>>,
}

impl Counter {
    /// What clicking `+` does.
    fn inc(&mut self, cx: &mut Context<Self>) {
        self.n += 1;
        cx.notify();
    }
    fn dec(&mut self, cx: &mut Context<Self>) {
        self.n -= 1;
        cx.notify();
    }
}

fn round(id: &'static str, label: &'static str) -> gpui::Stateful<gpui::Div> {
    div()
        .id(id)
        .size(px(40.))
        .flex()
        .items_center()
        .justify_center()
        .rounded_full()
        .border_1()
        .border_color(rgb(0xe4e4e7))
        .text_xl()
        .cursor_pointer()
        .hover(|s| s.bg(rgb(0xf4f4f5)))
        .child(label)
}

impl Render for Counter {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let mark = {
            let mut p = self.probe.borrow_mut();
            if p.state.is_some() && p.render.is_none() {
                p.render = Some(Instant::now());
                true
            } else {
                false
            }
        };
        if mark {
            let probe = self.probe.clone();
            window.on_next_frame(move |_, _| {
                probe.borrow_mut().frame.get_or_insert_with(Instant::now);
            });
        }
        div()
            .flex()
            .size_full()
            .items_center()
            .justify_center()
            .gap(px(20.))
            .bg(rgb(0xffffff))
            .text_color(rgb(0x09090b))
            .child(round("dec", "−").on_click(cx.listener(|this, _, _, cx| this.dec(cx))))
            .child(div().w(px(72.)).text_3xl().font_weight(gpui::FontWeight::SEMIBOLD).text_center().child(format!("{}", self.n)))
            .child(round("inc", "+").on_click(cx.listener(|this, _, _, cx| this.inc(cx))))
    }
}

fn main() {
    let n: usize = std::env::args().nth(1).and_then(|a| a.parse().ok()).unwrap_or(200);
    gpui_kit::application().with_assets(gpui_kit::assets::AllAssets).run(move |cx: &mut App| {
        let probe = Rc::new(RefCell::new(Probe::default()));
        let p = probe.clone();
        let bounds = Bounds::centered(None, size(px(300.), px(180.)), cx);
        let win = cx
            .open_window(WindowOptions { window_bounds: Some(WindowBounds::Windowed(bounds)), ..Default::default() }, |_, cx| {
                cx.new(|_| Counter { n: 0, probe: p })
            })
            .expect("open window");
        let view: Entity<Counter> = win.update(cx, |_, _, cx| cx.entity()).expect("view");
        cx.activate(true);
        cx.spawn(async move |cx: &mut AsyncApp| {
            cx.background_executor().timer(Duration::from_millis(1000)).await;
            let mut rows = Vec::new();
            for i in 0..n {
                *probe.borrow_mut() = Probe { t0: Some(Instant::now()), ..Default::default() };
                let _ = cx.update(|cx| {
                    view.update(cx, |c, cx| c.inc(cx));
                    probe.borrow_mut().state = Some(Instant::now());
                });
                let t = Instant::now();
                loop {
                    cx.background_executor().timer(Duration::from_micros(200)).await;
                    if probe.borrow().frame.is_some() || t.elapsed() > Duration::from_secs(5) {
                        break;
                    }
                }
                let p = std::mem::take(&mut *probe.borrow_mut());
                match p {
                    Probe { t0: Some(t0), state: Some(s), render: Some(r), frame: Some(f) } => rows.push([s - t0, r - t0, f - t0]),
                    _ => eprintln!("native_counter: click {i} timed out"),
                }
                cx.background_executor().timer(Duration::from_millis(97 + (i as u64 * 13) % 17)).await;
            }
            host::latency::report("native GPUI", &rows);
            let _ = cx.update(|cx| cx.quit());
        })
        .detach();
    });
}
