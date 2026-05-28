pub const ProjectComptimeSideEffect = extern struct {
    value: comptime_int = comptime sideEffect(),
};

fn sideEffect() comptime_int {
    @compileError("sentinel: project comptime side effect executed");
}
