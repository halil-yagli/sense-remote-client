# Sense Remote: anahtar betiklerinin ortak GitHub ortamı denetimi (kaynak olarak alınır).
#
#   check_environment <sahip/depo> <ortam> <izinli kural...>
#   (kural: "<tür>:<ad>", ör. "tag:v*", "branch:master")
#
# Sır yazılmadan önce ortamın VAR olduğu ve dal/etiket kuralının tam olarak beklenen kural
# olduğu doğrulanır: "Selected branches and tags" seçili (custom_branch_policies == true) ve
# kural listesi izinli kümeyle aynı. Ortam yoksa GitHub sırrı yazarken ortamı KORUMASIZ
# oluşturur; kural fazla ya da "All branches" ise sır o dallardan da okunabilir.
# Çağıran betikte die() tanımlı olmalı.

# Ortam ayarlarını açmanın tarifi (hata iletilerinde).
environment_help() {
  local repo=$1 environment=$2 rule
  shift 2
  echo "  Açmak/düzeltmek için: github.com/$repo › Settings › Environments › $environment"
  echo "  Deployment branches and tags › Selected branches and tags › yalnız şu kurallar:"
  for rule in "$@"; do
    echo "    Ref type: ${rule%%:*} › ${rule#*:}"
  done
}

check_environment() {
  local repo=$1 environment=$2 custom actual expected
  shift 2
  custom=$(gh api "repos/$repo/environments/$environment" \
    --jq '.deployment_branch_policy.custom_branch_policies // false' 2>/dev/null) \
    || die "GitHub ortamı '$environment' yok.
$(environment_help "$repo" "$environment" "$@")"
  [[ "$custom" == "true" ]] || die "GitHub ortamı '$environment' dal/etiket kuralıyla sınırlı değil (Selected branches and tags seçili değil).
$(environment_help "$repo" "$environment" "$@")"
  actual=$(gh api "repos/$repo/environments/$environment/deployment-branch-policies" \
    --jq '.branch_policies[] | "\(.type // "branch"):\(.name)"' 2>/dev/null) \
    || die "GitHub ortamı '$environment' kuralları okunamadı (gh yetkisi?)"
  actual=$(printf '%s\n' "$actual" | tr -d '\r' | sed '/^$/d' | LC_ALL=C sort -u)
  expected=$(printf '%s\n' "$@" | LC_ALL=C sort -u)
  [[ "$actual" == "$expected" ]] || die "GitHub ortamı '$environment' kuralları beklenenden farklı.
  Bulunan: $(tr '\n' ' ' <<<"$actual")
  Beklenen: $(tr '\n' ' ' <<<"$expected")
$(environment_help "$repo" "$environment" "$@")"
}
