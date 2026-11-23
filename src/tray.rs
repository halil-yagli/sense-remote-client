#[cfg(windows)]
use crate::ipc::Data;
// Sense Remote (YH C5, H6; decision #69): the menu items, tooltip and icon come from
// `sense::tray_menu`; the menu is the operating system's own.
use crate::sense::tray_menu::{self as sense_tray, Action as SenseTrayAction, Entry as SenseTrayEntry};
#[cfg(windows)]
use hbb_common::tokio;
use hbb_common::{allow_err, log};
use base::config::keys;
use std::sync::{Arc, Mutex};
#[cfg(windows)]
use std::time::Duration;

pub fn start_tray() {
    if crate::ui_interface::get_builtin_option(keys::OPTION_HIDE_TRAY) == "Y" {
        #[cfg(not(target_os = "macos"))]
        {
            return;
        }
    }

    #[cfg(target_os = "linux")]
    crate::server::check_zombie();

    allow_err!(make_tray());
}

fn make_tray() -> hbb_common::ResultType<()> {
    // https://github.com/tauri-apps/tray-icon/blob/dev/examples/tao.rs
    use hbb_common::anyhow::Context;
    use tao::event_loop::{ControlFlow, EventLoopBuilder};
    use tray_icon::{
        menu::{Menu, MenuEvent, MenuItem, PredefinedMenuItem},
        TrayIcon, TrayIconBuilder, TrayIconEvent as TrayEvent,
    };

    // Duplicated tray icons kept piling up through the blind spots of
    // `check_process("--tray", ..)`. https://github.com/rustdesk/rustdesk/issues/15689
    #[cfg(windows)]
    if !crate::platform::windows::try_lock_tray_single_instance() {
        log::info!("Another tray process is already running in this session, exit");
        return Ok(());
    }

    // Sense Remote (decision #70): the Sense mark, black on a light taskbar and white on a dark
    // one (Windows, followed while running); macOS draws the template in the bar's colour. The
    // app icon from the Flutter assets is not used for the tray.
    let load_icon = |bytes: &[u8]| -> hbb_common::ResultType<tray_icon::Icon> {
        let image = image::load_from_memory(bytes)
            .context("Failed to open icon path")?
            .into_rgba8();
        let (width, height) = image.dimensions();
        Ok(tray_icon::Icon::from_rgba(image.into_raw(), width, height)
            .context("Failed to open icon")?)
    };
    #[cfg(target_os = "macos")]
    let icon = load_icon(include_bytes!("../res/mac-tray-dark-x2.png"))?; // template
    #[cfg(windows)]
    let tray_icons = (
        load_icon(include_bytes!("../res/tray-light.ico"))?,
        load_icon(include_bytes!("../res/tray-dark.ico"))?,
    );
    #[cfg(windows)]
    let mut light_taskbar = sense_tray::taskbar_is_light();
    #[cfg(windows)]
    let icon = if light_taskbar {
        tray_icons.0.clone()
    } else {
        tray_icons.1.clone()
    };
    #[cfg(target_os = "linux")]
    let icon = match load_icon_from_asset() {
        Some(image) => {
            let image = image.into_rgba8();
            let (width, height) = image.dimensions();
            tray_icon::Icon::from_rgba(image.into_raw(), width, height)
                .context("Failed to open icon")?
        }
        None => load_icon(include_bytes!("../res/tray-icon.ico"))?,
    };

    let mut event_loop = EventLoopBuilder::new().build();

    // Sense Remote (YH C5, H6): Host: only "Sense Remote'u aç" (never "Servisi durdur": the
    // person at the computer can not stop the service from the tray). Controller: + the last 3
    // connections (one click connects) + "Çıkış yap". Rebuilt when the recent list changes.
    let controller = sense_tray::controller_menu(crate::sense::installed_role());
    let build_menu = move |recent: &[sense_tray::Recent]| -> Menu {
        let menu = Menu::new();
        for entry in sense_tray::menu(controller, recent, sense_tray::now_s()) {
            match entry {
                SenseTrayEntry::Item { id, label } => {
                    menu.append(&MenuItem::with_id(id, label, true, None)).ok();
                }
                SenseTrayEntry::Header(label) => {
                    menu.append(&MenuItem::new(label, false, None)).ok();
                }
                SenseTrayEntry::Separator => {
                    menu.append(&PredefinedMenuItem::separator()).ok();
                }
            }
        }
        menu
    };
    let mut recent = if controller {
        sense_tray::recent(sense_tray::RECENT_MAX)
    } else {
        vec![]
    };
    let tray_menu = build_menu(&recent);
    let mut last_refresh = std::time::Instant::now();
    let tooltip = sense_tray::tooltip;
    let mut _tray_icon: Arc<Mutex<Option<TrayIcon>>> = Default::default();

    let menu_channel = MenuEvent::receiver();
    let tray_channel = TrayEvent::receiver();
    #[cfg(windows)]
    let (ipc_sender, ipc_receiver) = std::sync::mpsc::channel::<Data>();

    let open_func = move || {
        if cfg!(not(feature = "flutter")) {
            crate::run_me::<&str>(vec![]).ok();
            return;
        }
        #[cfg(target_os = "macos")]
        crate::platform::macos::handle_application_should_open_untitled_file();
        #[cfg(target_os = "windows")]
        {
            // Do not use "start uni link" way, it may not work on some Windows, and pop out error
            // dialog, I found on one user's desktop, but no idea why, Windows is shit.
            // Use `run_me` instead.
            // `allow_multiple_instances` in `flutter/windows/runner/main.cpp` allows only one instance without args.
            crate::run_me::<&str>(vec![]).ok();
        }
        #[cfg(target_os = "linux")]
        {
            // Do not use "xdg-open", it won't read the config.
            if crate::dbus::invoke_new_connection(crate::get_uri_prefix()).is_err() {
                if let Ok(task) = crate::run_me::<&str>(vec![]) {
                    crate::server::CHILD_PROCESS.lock().unwrap().push(task);
                }
            }
        }
    };

    #[cfg(windows)]
    std::thread::spawn(move || {
        start_query_session_count(ipc_sender.clone());
    });
    #[cfg(windows)]
    let mut last_click = std::time::Instant::now();
    #[cfg(target_os = "macos")]
    {
        use tao::platform::macos::EventLoopExtMacOS;
        event_loop.set_activation_policy(tao::platform::macos::ActivationPolicy::Accessory);
    }
    event_loop.run(move |event, _, control_flow| {
        *control_flow = ControlFlow::WaitUntil(
            std::time::Instant::now() + std::time::Duration::from_millis(100),
        );

        if let tao::event::Event::NewEvents(tao::event::StartCause::Init) = event {
            // for fixing https://github.com/rustdesk/rustdesk/discussions/10210#discussioncomment-14600745
            // so we start tray, but not to show it
            if crate::ui_interface::get_builtin_option(keys::OPTION_HIDE_TRAY) == "Y" {
                return;
            }
            // We create the icon once the event loop is actually running
            // to prevent issues like https://github.com/tauri-apps/tray-icon/issues/90
            let mut builder = TrayIconBuilder::new()
                .with_id(crate::get_app_name().to_lowercase())
                .with_menu(Box::new(tray_menu.clone()))
                .with_tooltip(tooltip(0))
                .with_icon(icon.clone());
            #[cfg(target_os = "macos")]
            {
                builder = builder.with_icon_as_template(true);
            }
            #[cfg(target_os = "windows")]
            {
                // Required since tray-icon 0.17
                // Fixes #15215, #15222, #15410
                builder = builder.with_menu_on_left_click(false);
            }
            let tray = builder.build();
            match tray {
                Ok(tray) => _tray_icon = Arc::new(Mutex::new(Some(tray))),
                Err(err) => {
                    log::error!("Failed to create tray icon: {}", err);
                }
            };

            // We have to request a redraw here to have the icon actually show up.
            // Tao only exposes a redraw method on the Window so we use core-foundation directly.
            #[cfg(target_os = "macos")]
            unsafe {
                use core_foundation::runloop::{CFRunLoopGetMain, CFRunLoopWakeUp};

                let rl = CFRunLoopGetMain();
                CFRunLoopWakeUp(rl);
            }
        }

        // Sense Remote (YH C5, H6): what the Sense menu items do. There is no item that stops
        // the service.
        if let Ok(event) = menu_channel.try_recv() {
            match sense_tray::action_of(event.id.as_ref()) {
                Some(SenseTrayAction::Open) => open_func(),
                Some(SenseTrayAction::Connect(peer_id)) => {
                    allow_err!(crate::run_me(vec!["--connect", peer_id.as_str()]));
                }
                Some(SenseTrayAction::SignOut) => sense_sign_out(),
                None => {}
            }
        }

        // Sense Remote: every 5 s, the recent list (Controller) and the taskbar colour (Windows).
        if last_refresh.elapsed() >= std::time::Duration::from_secs(5) {
            last_refresh = std::time::Instant::now();
            if controller {
                let now = sense_tray::recent(sense_tray::RECENT_MAX);
                if now != recent {
                    recent = now;
                    let menu = build_menu(&recent);
                    if let Some(tray) = _tray_icon.lock().unwrap().as_mut() {
                        tray.set_menu(Some(Box::new(menu)));
                    }
                }
            }
            #[cfg(windows)]
            {
                let light = sense_tray::taskbar_is_light();
                if light != light_taskbar {
                    light_taskbar = light;
                    let icon = if light {
                        tray_icons.0.clone()
                    } else {
                        tray_icons.1.clone()
                    };
                    if let Some(tray) = _tray_icon.lock().unwrap().as_mut() {
                        allow_err!(tray.set_icon(Some(icon)));
                    }
                }
            }
        }

        if let Ok(_event) = tray_channel.try_recv() {
            #[cfg(target_os = "windows")]
            match _event {
                TrayEvent::Click {
                    button,
                    button_state,
                    ..
                } => {
                    if button == tray_icon::MouseButton::Left
                        && button_state == tray_icon::MouseButtonState::Up
                    {
                        if last_click.elapsed() < std::time::Duration::from_secs(1) {
                            return;
                        }
                        open_func();
                        last_click = std::time::Instant::now();
                    }
                }
                _ => {}
            }
        }

        #[cfg(windows)]
        if let Ok(data) = ipc_receiver.try_recv() {
            match data {
                Data::ControlledSessionCount(count) => {
                    _tray_icon
                        .lock()
                        .unwrap()
                        .as_mut()
                        .map(|t| t.set_tooltip(Some(tooltip(count))));
                }
                _ => {}
            }
        }
    });
}

#[cfg(windows)]
#[tokio::main(flavor = "current_thread")]
async fn start_query_session_count(sender: std::sync::mpsc::Sender<Data>) {
    let mut last_count = 0;
    loop {
        if let Ok(mut c) = crate::ipc::connect(1000, "").await {
            let mut timer = crate::rustdesk_interval(tokio::time::interval(Duration::from_secs(1)));
            loop {
                tokio::select! {
                    res = c.next() => {
                        match res {
                            Err(err) => {
                                log::error!("ipc connection closed: {}", err);
                                break;
                            }

                            Ok(Some(Data::ControlledSessionCount(count))) => {
                                if count != last_count {
                                    last_count = count;
                                    sender.send(Data::ControlledSessionCount(count)).ok();
                                }
                            }
                            _ => {}
                        }
                    }

                    _ = timer.tick() => {
                        c.send(&Data::ControlledSessionCount(0)).await.ok();
                    }
                }
            }
        }
        hbb_common::sleep(1.).await;
    }
}

/// Sense Remote (YH C5): "Çıkış yap" in the tray. The open app window signs out itself (the
/// link `<scheme>://sense-signout`, `tray_link.dart`: only without an open connection), so its
/// memory and the stored session agree. Without an open window the stored session is removed
/// here.
fn sense_sign_out() {
    let link = sense_tray::sign_out_link();
    #[cfg(windows)]
    let handed = crate::platform::send_message_to_hnwd(
        &crate::platform::FLUTTER_RUNNER_WIN32_WINDOW_CLASS,
        &crate::get_app_name(),
        (winapi::um::winuser::WM_USER + 2) as _, // the app's link message (`core_main`)
        &link,
        true,
    );
    #[cfg(target_os = "macos")]
    let handed = crate::ipc::send_url_scheme(link).is_ok();
    #[cfg(target_os = "linux")]
    let handed = crate::dbus::invoke_new_connection(link).is_ok();
    if !handed {
        use hbb_common::config::LocalConfig;
        LocalConfig::set_option("access_token".to_owned(), String::new());
        LocalConfig::set_option("user_info".to_owned(), String::new());
        log::info!("Sense Remote: signed out from the tray");
    }
}

#[cfg(target_os = "linux")]
fn load_icon_from_asset() -> Option<image::DynamicImage> {
    let Some(path) = std::env::current_exe().map_or(None, |x| x.parent().map(|x| x.to_path_buf()))
    else {
        return None;
    };
    #[cfg(target_os = "macos")]
    let path = path.join("../Frameworks/App.framework/Resources/flutter_assets/assets/icon.png");
    #[cfg(windows)]
    let path = path.join(r"data\flutter_assets\assets\icon.png");
    #[cfg(target_os = "linux")]
    let path = path.join(r"data/flutter_assets/assets/icon.png");
    if path.exists() {
        if let Ok(image) = image::open(path) {
            return Some(image);
        }
    }
    None
}
