//! uitcore.h's functions, declared for Zig: the spike calls the core only
//! the way a renderer does, through the C ABI's exports.

const core = @import("uitcore");
const abi = core.abi;
const Core = abi.Core;
const S = abi.UitStr;
const N = abi.UitNode;

pub extern fn uit_create(cfg: ?*const abi.UitConfig, out: ?*?*Core) c_int;
pub extern fn uit_themes(c: *Core, text: S) c_int;
pub extern fn uit_run_machine(c: *Core, args: ?*const abi.UitMachineArgs) c_int;
pub extern fn uit_last_error(c: *Core) S;
pub extern fn uit_pump(c: *Core, out: ?*abi.UitChanges) c_int;
pub extern fn uit_prop(c: *Core, h: N, file: S, out: ?*S) c_int;
pub extern fn uit_theme_dark(c: *Core) u32;
pub extern fn uit_token_text(c: *Core, name: S, out: ?*S) c_int;
pub extern fn uit_emit(c: *Core, h: N, name: S, attrs: ?[*]const abi.UitAttr, n: usize) c_int;
pub extern fn uit_request(c: *Core, h: N, name: S, attrs: ?[*]const abi.UitAttr, n: usize, default_answer: S) u64;
pub extern fn uit_mirror(c: *Core, h: N, file: S, value: S) c_int;
pub extern fn uit_bounds(c: *Core, h: N, x: f32, y: f32, w: f32, hh: f32) c_int;
pub extern fn uit_frame_drawn(c: *Core, win: S) c_int;
pub extern fn uit_window_closed(c: *Core, win: S) c_int;
pub extern fn uit_key(c: *Core, win: S, keystroke: S, focused: N) c_int;
pub extern fn uit_menu_action(c: *Core, id: S) c_int;
pub extern fn uit_system_dark(c: *Core, dark: u32) c_int;
