// platform/build.rs
fn main() {
    // Roc's `roc build --no-link` produces an object file (app.o).
    // We convert it to a static library (libapp.a) via `ar rcs`.
    // Static linking allows the host binary to provide roc_alloc/roc_dealloc/roc_panic
    // symbols that the compiled Roc code references.
    let platform_path =
        std::env::current_dir().expect("Failed to get current directory");

    println!(
        "cargo:rustc-link-search=native={}",
        platform_path.display()
    );
    println!("cargo:rustc-link-lib=static=app");
}
