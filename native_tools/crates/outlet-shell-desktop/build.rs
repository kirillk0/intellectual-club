#[cfg(windows)]
fn main() {
    use std::path::PathBuf;

    let manifest_dir = PathBuf::from(std::env::var_os("CARGO_MANIFEST_DIR").unwrap());
    let icon_source = manifest_dir.join("../../../frontend/src/assets/icon_outlet_full.png");
    println!("cargo:rerun-if-changed={}", icon_source.display());

    let icon_path = PathBuf::from(std::env::var_os("OUT_DIR").unwrap()).join("outlet.ico");
    write_icon(&icon_source, &icon_path);

    let mut resource = winresource::WindowsResource::new();
    resource.set_icon(icon_path.to_str().expect("UTF-8 icon path"));
    resource
        .compile()
        .expect("compile outlet Windows resources");
}

#[cfg(windows)]
fn write_icon(source: &std::path::Path, target: &std::path::Path) {
    let image = image::open(source).expect("read outlet icon").resize_exact(
        256,
        256,
        image::imageops::FilterType::Lanczos3,
    );
    let mut file = std::fs::File::create(target).expect("create outlet ICO");
    image
        .write_to(&mut file, image::ImageFormat::Ico)
        .expect("encode outlet ICO");
}

#[cfg(not(windows))]
fn main() {}
