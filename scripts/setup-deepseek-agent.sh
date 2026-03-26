#!/usr/bin/env bash
#
# setup-deepseek-agent.sh
# Полный пайплайн установки агента на базе DeepSeek API с reasoning на Ubuntu.
# Использует qwen-code — open-source AI-агент для терминала.
#
# Поддерживаемые модели DeepSeek:
#   deepseek-reasoner  — модель с reasoning (R1), 128K контекст, 64K выход
#   deepseek-r1        — альтернативное имя reasoning-модели
#   deepseek-chat      — стандартная чат-модель, 128K контекст, 8K выход
#
# Использование:
#   chmod +x scripts/setup-deepseek-agent.sh
#   ./scripts/setup-deepseek-agent.sh
#
# Или одной командой с нуля (форк + клон + установка):
#   curl -fsSL https://raw.githubusercontent.com/romannekrasovaillm/qwen-code/main/scripts/setup-deepseek-agent.sh | bash
#
set -euo pipefail

# ─────────────────────────── Цвета и утилиты ────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
step()    { echo -e "\n${CYAN}══════════════════════════════════════════════════════${NC}"; \
            echo -e "${CYAN}  $*${NC}"; \
            echo -e "${CYAN}══════════════════════════════════════════════════════${NC}\n"; }

# ─────────────────────── Конфигурация по умолчанию ───────────────────────

GITHUB_UPSTREAM="https://github.com/anthropics/claude-code.git"  # upstream (оригинал)
REPO_NAME="qwen-code"
INSTALL_DIR="${INSTALL_DIR:-$HOME/$REPO_NAME}"
NODE_MIN_VERSION="20"
DEEPSEEK_MODEL="${DEEPSEEK_MODEL:-deepseek-reasoner}"
DEEPSEEK_BASE_URL="https://api.deepseek.com/v1"
SETTINGS_DIR="$HOME/.config/qwen-code"
SETTINGS_FILE="$SETTINGS_DIR/settings.json"

# ═══════════════════════════════════════════════════════════════════════════
#  ШАГ 0: Проверка ОС
# ═══════════════════════════════════════════════════════════════════════════

step "Шаг 0/7: Проверка операционной системы"

if [[ ! -f /etc/os-release ]]; then
    error "Не удалось определить ОС. Скрипт рассчитан на Ubuntu."
    exit 1
fi

source /etc/os-release
if [[ "$ID" != "ubuntu" && "$ID_LIKE" != *"ubuntu"* && "$ID_LIKE" != *"debian"* ]]; then
    warn "Обнаружена ОС: $PRETTY_NAME. Скрипт тестирован на Ubuntu, но может работать на Debian-совместимых."
fi
success "ОС: $PRETTY_NAME"

# ═══════════════════════════════════════════════════════════════════════════
#  ШАГ 1: Установка системных зависимостей
# ═══════════════════════════════════════════════════════════════════════════

step "Шаг 1/7: Установка системных зависимостей"

install_if_missing() {
    local cmd="$1"
    local pkg="${2:-$1}"
    if command -v "$cmd" &>/dev/null; then
        success "$cmd уже установлен: $(command -v "$cmd")"
        return 0
    fi
    info "Устанавливаю $pkg..."
    sudo apt-get install -y "$pkg"
    success "$pkg установлен"
}

info "Обновляю списки пакетов..."
sudo apt-get update -qq

install_if_missing git git
install_if_missing curl curl
install_if_missing jq jq
install_if_missing make build-essential

# ═══════════════════════════════════════════════════════════════════════════
#  ШАГ 2: Установка Node.js (>= 20)
# ═══════════════════════════════════════════════════════════════════════════

step "Шаг 2/7: Проверка и установка Node.js >= $NODE_MIN_VERSION"

install_node() {
    info "Устанавливаю Node.js $NODE_MIN_VERSION через NodeSource..."
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_MIN_VERSION}.x" | sudo -E bash -
    sudo apt-get install -y nodejs
}

if command -v node &>/dev/null; then
    CURRENT_NODE=$(node -v | sed 's/v//' | cut -d. -f1)
    if (( CURRENT_NODE >= NODE_MIN_VERSION )); then
        success "Node.js $(node -v) уже установлен"
    else
        warn "Node.js $(node -v) слишком старый, нужна версия >= $NODE_MIN_VERSION"
        install_node
    fi
else
    install_node
fi

success "Node.js $(node -v)"
success "npm $(npm -v)"

# ═══════════════════════════════════════════════════════════════════════════
#  ШАГ 3: Форк и клонирование репозитория
# ═══════════════════════════════════════════════════════════════════════════

step "Шаг 3/7: Форк и клонирование репозитория (через GitHub API + git)"

UPSTREAM_OWNER="QwenLM"
UPSTREAM_REPO="qwen-code"
GITHUB_API="https://api.github.com"

# --- 3a: Получение GitHub токена ---
if [[ -z "${GITHUB_TOKEN:-}" ]]; then
    warn "Переменная GITHUB_TOKEN не установлена."
    echo ""
    echo -e "  ${YELLOW}Для форка нужен GitHub Personal Access Token (PAT).${NC}"
    echo ""
    echo -e "  Создайте токен: ${CYAN}https://github.com/settings/tokens/new${NC}"
    echo -e "  Нужные права: ${CYAN}repo${NC} (полный доступ к репозиториям)"
    echo ""
    read -rp "  Введите GitHub Personal Access Token: " GITHUB_TOKEN

    if [[ -z "$GITHUB_TOKEN" ]]; then
        error "Токен не введён. Без него форк через API невозможен."
        error "Установите: export GITHUB_TOKEN='ghp_ваш_токен'"
        exit 1
    fi
    export GITHUB_TOKEN
fi

# --- 3b: Проверка токена и получение имени пользователя ---
info "Проверяю токен GitHub..."
GH_USER_RESPONSE=$(curl -s -w "\n%{http_code}" \
    -H "Authorization: token $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github.v3+json" \
    "$GITHUB_API/user")

GH_HTTP_CODE=$(echo "$GH_USER_RESPONSE" | tail -1)
GH_USER_JSON=$(echo "$GH_USER_RESPONSE" | sed '$d')

if [[ "$GH_HTTP_CODE" != "200" ]]; then
    error "Токен невалиден (HTTP $GH_HTTP_CODE)."
    error "Ответ: $(echo "$GH_USER_JSON" | jq -r '.message // .' 2>/dev/null)"
    exit 1
fi

GH_USER=$(echo "$GH_USER_JSON" | jq -r '.login')
GH_NAME=$(echo "$GH_USER_JSON" | jq -r '.name // "не указано"')
success "Авторизован как: $GH_USER ($GH_NAME)"

# Сохраняем токен в .bashrc для git credential
SHELL_RC="$HOME/.bashrc"
if [[ -f "$HOME/.zshrc" ]] && [[ "${SHELL:-}" == *"zsh"* ]]; then
    SHELL_RC="$HOME/.zshrc"
fi
if ! grep -q "GITHUB_TOKEN" "$SHELL_RC" 2>/dev/null; then
    echo "" >> "$SHELL_RC"
    echo "# GitHub Token (добавлено setup-deepseek-agent.sh)" >> "$SHELL_RC"
    echo "export GITHUB_TOKEN=\"$GITHUB_TOKEN\"" >> "$SHELL_RC"
    info "GITHUB_TOKEN сохранён в $SHELL_RC"
fi

# --- 3c: Создание форка через GitHub REST API ---
if [[ -d "$INSTALL_DIR/.git" ]]; then
    info "Репозиторий уже существует в $INSTALL_DIR"
    cd "$INSTALL_DIR"
    info "Обновляю до последней версии..."
    git fetch origin main 2>/dev/null
    git checkout main 2>/dev/null
    git pull origin main 2>/dev/null || warn "Не удалось обновить, продолжаю с текущей версией"

    # Проверяем что upstream remote настроен
    if ! git remote get-url upstream &>/dev/null; then
        info "Добавляю upstream remote..."
        git remote add upstream "https://github.com/${UPSTREAM_OWNER}/${UPSTREAM_REPO}.git"
        success "upstream remote добавлен"
    fi
else
    # Проверяем, существует ли уже форк у пользователя
    info "Проверяю существование форка ${GH_USER}/${UPSTREAM_REPO}..."
    FORK_CHECK=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "Authorization: token $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github.v3+json" \
        "$GITHUB_API/repos/${GH_USER}/${UPSTREAM_REPO}")

    if [[ "$FORK_CHECK" == "200" ]]; then
        info "Форк ${GH_USER}/${UPSTREAM_REPO} уже существует"
    else
        info "Создаю форк ${UPSTREAM_OWNER}/${UPSTREAM_REPO} -> ${GH_USER}/${UPSTREAM_REPO}..."

        FORK_RESPONSE=$(curl -s -w "\n%{http_code}" \
            -X POST \
            -H "Authorization: token $GITHUB_TOKEN" \
            -H "Accept: application/vnd.github.v3+json" \
            "$GITHUB_API/repos/${UPSTREAM_OWNER}/${UPSTREAM_REPO}/forks" \
            -d '{"default_branch_only": true}')

        FORK_HTTP=$(echo "$FORK_RESPONSE" | tail -1)
        FORK_JSON=$(echo "$FORK_RESPONSE" | sed '$d')

        if [[ "$FORK_HTTP" == "202" || "$FORK_HTTP" == "200" ]]; then
            FORK_URL=$(echo "$FORK_JSON" | jq -r '.html_url')
            success "Форк создан: $FORK_URL"
        else
            error "Не удалось создать форк (HTTP $FORK_HTTP)"
            error "Ответ: $(echo "$FORK_JSON" | jq -r '.message // .' 2>/dev/null)"
            exit 1
        fi

        # GitHub создаёт форк асинхронно — ждём готовности
        info "Ожидаю готовность форка (GitHub создаёт его асинхронно)..."
        for i in {1..30}; do
            READY=$(curl -s -o /dev/null -w "%{http_code}" \
                -H "Authorization: token $GITHUB_TOKEN" \
                -H "Accept: application/vnd.github.v3+json" \
                "$GITHUB_API/repos/${GH_USER}/${UPSTREAM_REPO}")
            if [[ "$READY" == "200" ]]; then
                success "Форк готов (попытка $i)"
                break
            fi
            if [[ "$i" == "30" ]]; then
                error "Форк не стал доступен за 60 секунд"
                exit 1
            fi
            sleep 2
        done
    fi

    # --- 3d: Клонирование форка через git ---
    CLONE_URL="https://${GH_USER}:${GITHUB_TOKEN}@github.com/${GH_USER}/${UPSTREAM_REPO}.git"
    DEFAULT_BRANCH="main"

    info "Клонирую форк (ветка: $DEFAULT_BRANCH)..."
    git clone --branch "$DEFAULT_BRANCH" --single-branch "$CLONE_URL" "$INSTALL_DIR"
    cd "$INSTALL_DIR"

    # Убираем токен из сохранённого remote URL (безопасность)
    git remote set-url origin "https://github.com/${GH_USER}/${UPSTREAM_REPO}.git"

    # Настраиваем git credential helper чтобы использовать токен
    git config credential.helper store
    # Записываем credentials для автоматического пуша
    mkdir -p "$HOME"
    CRED_FILE="$HOME/.git-credentials"
    if ! grep -q "github.com" "$CRED_FILE" 2>/dev/null; then
        echo "https://${GH_USER}:${GITHUB_TOKEN}@github.com" >> "$CRED_FILE"
        chmod 600 "$CRED_FILE"
        info "Git credentials сохранены в $CRED_FILE"
    fi

    # Добавляем upstream remote
    git remote add upstream "https://github.com/${UPSTREAM_OWNER}/${UPSTREAM_REPO}.git"

    success "Форк склонирован в $INSTALL_DIR"
fi

# --- 3e: Синхронизация форка с upstream ---
info "Синхронизирую форк с upstream..."
git fetch origin main 2>/dev/null
git fetch upstream main 2>/dev/null && {
    git checkout main 2>/dev/null
    git merge upstream/main --no-edit 2>/dev/null || warn "Merge не требуется или возник конфликт"
    git push origin main 2>/dev/null || warn "Не удалось запушить в origin"
    success "Форк синхронизирован с upstream"
} || warn "Не удалось синхронизировать (upstream может быть недоступен)"

# Показываем итоговое состояние
echo ""
info "Настроенные remote:"
git remote -v | while read -r line; do
    echo "  $line"
done

success "Репозиторий готов: $(pwd)"
success "Текущий коммит: $(git log --oneline -1)"

# ═══════════════════════════════════════════════════════════════════════════
#  ШАГ 4: Установка зависимостей и сборка
# ═══════════════════════════════════════════════════════════════════════════

step "Шаг 4/7: Установка npm-зависимостей и сборка проекта"

info "npm install (это может занять несколько минут)..."
npm install 2>&1 | tail -5

info "Сборка проекта..."
npm run build 2>&1 | tail -10

success "Проект собран"

# ═══════════════════════════════════════════════════════════════════════════
#  ШАГ 5: Настройка DeepSeek API ключа
# ═══════════════════════════════════════════════════════════════════════════

step "Шаг 5/7: Настройка API-ключа DeepSeek"

if [[ -n "${DEEPSEEK_API_KEY:-}" ]]; then
    success "Переменная DEEPSEEK_API_KEY уже установлена"
else
    warn "Переменная DEEPSEEK_API_KEY не найдена в окружении."
    echo ""
    echo -e "  ${YELLOW}Получите API-ключ на: https://platform.deepseek.com/api_keys${NC}"
    echo ""
    read -rp "  Введите ваш DeepSeek API ключ (или Enter чтобы пропустить): " INPUT_KEY

    if [[ -n "$INPUT_KEY" ]]; then
        export DEEPSEEK_API_KEY="$INPUT_KEY"

        # Добавляем в .bashrc для сохранения между сессиями
        SHELL_RC="$HOME/.bashrc"
        if [[ -f "$HOME/.zshrc" ]] && [[ "$SHELL" == *"zsh"* ]]; then
            SHELL_RC="$HOME/.zshrc"
        fi

        if ! grep -q "DEEPSEEK_API_KEY" "$SHELL_RC" 2>/dev/null; then
            echo "" >> "$SHELL_RC"
            echo "# DeepSeek API Key (добавлено setup-deepseek-agent.sh)" >> "$SHELL_RC"
            echo "export DEEPSEEK_API_KEY=\"$INPUT_KEY\"" >> "$SHELL_RC"
            success "API-ключ сохранён в $SHELL_RC"
        fi
    else
        warn "API-ключ не задан. Установите позже: export DEEPSEEK_API_KEY='ваш_ключ'"
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
#  ШАГ 6: Конфигурация агента для DeepSeek Reasoner
# ═══════════════════════════════════════════════════════════════════════════

step "Шаг 6/7: Конфигурация модели DeepSeek Reasoner"

mkdir -p "$SETTINGS_DIR"

# Создаём или обновляем settings.json
if [[ -f "$SETTINGS_FILE" ]]; then
    info "Файл настроек существует, обновляю конфигурацию модели..."
    # Создаём бэкап
    cp "$SETTINGS_FILE" "${SETTINGS_FILE}.bak.$(date +%s)"

    # Обновляем через jq
    TMP_SETTINGS=$(mktemp)
    jq --arg model "$DEEPSEEK_MODEL" \
       --arg baseUrl "$DEEPSEEK_BASE_URL" \
       '
       .modelProviders.use_openai = (
         (.modelProviders.use_openai // [])
         | map(select(.id != "deepseek-reasoner" and .id != "deepseek-chat" and .id != "deepseek-r1"))
         | . + [
             {
               "id": "deepseek-reasoner",
               "name": "DeepSeek Reasoner (R1)",
               "baseUrl": $baseUrl,
               "envKey": "DEEPSEEK_API_KEY",
               "generationConfig": {
                 "timeout": 300000,
                 "maxRetries": 3
               }
             },
             {
               "id": "deepseek-chat",
               "name": "DeepSeek Chat (V3)",
               "baseUrl": $baseUrl,
               "envKey": "DEEPSEEK_API_KEY",
               "generationConfig": {
                 "timeout": 120000,
                 "maxRetries": 3
               }
             }
           ]
       )
       | .model = $model
       ' "$SETTINGS_FILE" > "$TMP_SETTINGS"

    mv "$TMP_SETTINGS" "$SETTINGS_FILE"
else
    info "Создаю новый файл настроек..."
    cat > "$SETTINGS_FILE" <<SETTINGS_EOF
{
  "model": "$DEEPSEEK_MODEL",
  "modelProviders": {
    "use_openai": [
      {
        "id": "deepseek-reasoner",
        "name": "DeepSeek Reasoner (R1)",
        "baseUrl": "$DEEPSEEK_BASE_URL",
        "envKey": "DEEPSEEK_API_KEY",
        "generationConfig": {
          "timeout": 300000,
          "maxRetries": 3
        }
      },
      {
        "id": "deepseek-chat",
        "name": "DeepSeek Chat (V3)",
        "baseUrl": "$DEEPSEEK_BASE_URL",
        "envKey": "DEEPSEEK_API_KEY",
        "generationConfig": {
          "timeout": 120000,
          "maxRetries": 3
        }
      }
    ]
  }
}
SETTINGS_EOF
fi

success "Конфигурация сохранена: $SETTINGS_FILE"
info "Активная модель: $DEEPSEEK_MODEL"
echo ""
info "Содержимое конфигурации:"
jq '.' "$SETTINGS_FILE"

# ═══════════════════════════════════════════════════════════════════════════
#  ШАГ 7: Создание удобных скриптов запуска
# ═══════════════════════════════════════════════════════════════════════════

step "Шаг 7/7: Создание скриптов запуска"

# Скрипт для запуска агента
LAUNCHER="$INSTALL_DIR/run-deepseek-agent.sh"
cat > "$LAUNCHER" <<'LAUNCHER_EOF'
#!/usr/bin/env bash
# Запуск qwen-code агента с DeepSeek Reasoner
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [[ -z "${DEEPSEEK_API_KEY:-}" ]]; then
    echo "ОШИБКА: Переменная DEEPSEEK_API_KEY не установлена."
    echo "Выполните: export DEEPSEEK_API_KEY='ваш_ключ'"
    exit 1
fi

echo "Запускаю агент с моделью DeepSeek Reasoner..."
echo "Для выхода нажмите Ctrl+C или введите /exit"
echo ""

# Запуск CLI
node packages/cli/dist/cli.js "$@"
LAUNCHER_EOF
chmod +x "$LAUNCHER"
success "Скрипт запуска: $LAUNCHER"

# Скрипт для проверки соединения с API
HEALTHCHECK="$INSTALL_DIR/test-deepseek-connection.sh"
cat > "$HEALTHCHECK" <<'HEALTH_EOF'
#!/usr/bin/env bash
# Проверка подключения к DeepSeek API
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "Проверка подключения к DeepSeek API..."
echo ""

if [[ -z "${DEEPSEEK_API_KEY:-}" ]]; then
    echo -e "${RED}ОШИБКА: DEEPSEEK_API_KEY не установлен${NC}"
    echo "Установите: export DEEPSEEK_API_KEY='ваш_ключ'"
    exit 1
fi

echo "1. Проверяю доступность API..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    --max-time 10 \
    "https://api.deepseek.com/v1/models" \
    -H "Authorization: Bearer $DEEPSEEK_API_KEY")

if [[ "$HTTP_CODE" == "200" ]]; then
    echo -e "   ${GREEN}API доступен (HTTP $HTTP_CODE)${NC}"
else
    echo -e "   ${RED}Ошибка: HTTP $HTTP_CODE${NC}"
    exit 1
fi

echo ""
echo "2. Доступные модели:"
curl -s "https://api.deepseek.com/v1/models" \
    -H "Authorization: Bearer $DEEPSEEK_API_KEY" \
    | jq -r '.data[].id' 2>/dev/null | sort | while read -r model; do
    echo "   - $model"
done

echo ""
echo "3. Тестовый запрос к deepseek-reasoner..."
RESPONSE=$(curl -s --max-time 60 \
    "https://api.deepseek.com/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $DEEPSEEK_API_KEY" \
    -d '{
        "model": "deepseek-reasoner",
        "messages": [{"role": "user", "content": "Сколько будет 25 * 17? Ответь кратко."}],
        "max_tokens": 200
    }')

if echo "$RESPONSE" | jq -e '.choices[0].message.content' &>/dev/null; then
    ANSWER=$(echo "$RESPONSE" | jq -r '.choices[0].message.content')
    REASONING=$(echo "$RESPONSE" | jq -r '.choices[0].message.reasoning_content // empty')

    if [[ -n "$REASONING" ]]; then
        echo -e "   ${GREEN}Reasoning:${NC}"
        echo "   $REASONING" | head -5
        echo ""
    fi
    echo -e "   ${GREEN}Ответ: $ANSWER${NC}"
    echo ""

    USAGE=$(echo "$RESPONSE" | jq '.usage')
    echo "   Использование токенов: $USAGE"
    echo ""
    echo -e "${GREEN}Всё работает! Запустите агент: ./run-deepseek-agent.sh${NC}"
else
    echo -e "${RED}Ошибка в ответе:${NC}"
    echo "$RESPONSE" | jq '.' 2>/dev/null || echo "$RESPONSE"
    exit 1
fi
HEALTH_EOF
chmod +x "$HEALTHCHECK"
success "Скрипт проверки: $HEALTHCHECK"

# ═══════════════════════════════════════════════════════════════════════════
#  ИТОГО
# ═══════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Установка завершена!${NC}"
echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${CYAN}Директория проекта:${NC}  $INSTALL_DIR"
echo -e "  ${CYAN}Конфигурация:${NC}        $SETTINGS_FILE"
echo -e "  ${CYAN}Активная модель:${NC}     $DEEPSEEK_MODEL"
echo ""
echo -e "  ${YELLOW}Следующие шаги:${NC}"
echo ""
echo "  1. Убедитесь что API-ключ установлен:"
echo -e "     ${CYAN}export DEEPSEEK_API_KEY='sk-...'${NC}"
echo ""
echo "  2. Проверьте подключение к API:"
echo -e "     ${CYAN}cd $INSTALL_DIR && ./test-deepseek-connection.sh${NC}"
echo ""
echo "  3. Запустите агента:"
echo -e "     ${CYAN}cd $INSTALL_DIR && ./run-deepseek-agent.sh${NC}"
echo ""
echo "  4. Или запустите с конкретным промптом:"
echo -e "     ${CYAN}./run-deepseek-agent.sh -p 'Напиши функцию сортировки на Python'${NC}"
echo ""
echo -e "  ${YELLOW}Переключение моделей:${NC}"
echo "  - deepseek-reasoner  — с reasoning (цепочка рассуждений)"
echo "  - deepseek-chat      — быстрый чат без reasoning"
echo ""
echo -e "  Смена модели в конфиге:"
echo -e "     ${CYAN}jq '.model = \"deepseek-chat\"' $SETTINGS_FILE > /tmp/s.json && mv /tmp/s.json $SETTINGS_FILE${NC}"
echo ""
