-- Sense Remote (Mac M2, plan 2026-11-21 section 3.2): the shell script and the prompt text
-- come from Rust (src/sense/identity/mac_script.rs install_script, install_mac.rs
-- PROMPT_INSTALL), where the allowed values and the step order are tested. Upstream built the
-- shell text here and copied the config into a directory that might not exist.
on run {sh, prompt_text}
  do shell script sh with prompt prompt_text with administrator privileges
end run
