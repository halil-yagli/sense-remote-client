-- Sense Remote (Mac M2, plan 2026-11-21 section 3.2): the shell script and the prompt text
-- come from Rust (src/sense/identity/mac_script.rs uninstall_script, install_mac.rs
-- PROMPT_UNINSTALL).
on run {sh, prompt_text}
  do shell script sh with prompt prompt_text with administrator privileges
end run
