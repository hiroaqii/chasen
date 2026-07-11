/// Fixed effect queue bounds shared by Ctx storage and Program-owned helper
/// buffers. Keep these internal so capacity bookkeeping does not become part
/// of the public application API.
pub const max_tasks: usize = 16;
pub const max_terminal_image_loads: usize = 8;
