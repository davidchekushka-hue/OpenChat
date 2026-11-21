#!/bin/bash

CONFIG_FILE="$HOME/.ai_chat_config"

# Красивый зелёный баннер при запуске
echo -e "\033[1;32m"
if command -v figlet >/dev/null 2>&1; then
    figlet "OpenChat"
else
    echo "=== OpenChat ==="
fi
echo -e "\033[0m"

if [[ "$1" == "--reset" ]]; then
    rm -f "$CONFIG_FILE"
    echo "Настройки сброшены."
fi

if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
else
    read -erp "Введите Base URL [по умолчанию: https://openai.com]: " BASE_URL
    BASE_URL="${BASE_URL:-https://openai.com}"

    read -rsp "Введите ваш API-ключ: " API_KEY
    echo ""
    if [ -z "$API_KEY" ]; then
        echo "Ошибка: API-ключ не может быть пустым."
        exit 1
    fi

    read -erp "Введите модель [по умолчанию: deepseek-chat]: " MODEL
    MODEL="${MODEL:-deepseek-chat}"

    cat << CONF > "$CONFIG_FILE"
BASE_URL="$BASE_URL"
API_KEY="$API_KEY"
MODEL="$MODEL"
CONF
    chmod 600 "$CONFIG_FILE"
    echo "Настройки сохранены в $CONFIG_FILE"
fi

API_URL="${BASE_URL%/}/chat/completions"
DISPLAY_VAL="${DISPLAY:-:0}"
SYS_INFO=$(uname -srm; lsb_release -ds 2>/dev/null; echo "User: $USER, Dir: $PWD, DISPLAY: $DISPLAY_VAL")

HISTORY_FILE=$(mktemp)
REPLY_FILE=$(mktemp)
RAW_REPLY_FILE=$(mktemp)

init_history() {
    python3 -c '
import sys, json
_, hist_file, sys_info = sys.argv
sys_prompt = (
    f"Ты полностью автономный системный ИИ-агент в Linux (Ubuntu) с прямым доступом к терминалу и графическому рабочему столу (GUI). Система:\n{sys_info}\n\n"
    "ПРАВИЛА РАБОТЫ С ОС, GUI-ПРИЛОЖЕНИЯМИ И БРАУЗЕРОМ:\n"
    "1. Для взаимодействия с ОС и приложениями пиши ровно ОДНУ bash-команду за шаг внутри тегов [CMD]команда[/CMD]. Команда выполнится автоматически.\n"
    "2. ОТКРЫТИЕ ВКЛАДОК И САЙТОВ: Для открытия URL или локальных HTML-файлов в браузере используй:\n"
    "   DISPLAY=:0 nohup xdg-open \"https://example.com\" >/dev/null 2>&1 </dev/null &\n"
    "3. ЗАПУСК GUI-ПРИЛОЖЕНИЙ: Любые графические программы (gnome-terminal, firefox, google-chrome, code, nautilus и др.) ВСЕГДА запускай в фоне с отвязкой вывода:\n"
    "   DISPLAY=:0 nohup имя_программы >/dev/null 2>&1 </dev/null &\n"
    "4. УПРАВЛЕНИЕ ОКНАМИ, КЛАВИАТУРОЙ И БУФЕРОМ (wmctrl / xdotool / xclip):\n"
    "   - Список открытых окон: DISPLAY=:0 wmctrl -l\n"
    "   - Переключиться на окно: DISPLAY=:0 wmctrl -a \"Часть заголовка\"\n"
    "   - Нажать клавиши: DISPLAY=:0 xdotool key ctrl+t\n"
    "   - Ввести текст: DISPLAY=:0 xdotool type --delay 30 \"текст\"\n"
    "   - Прочитать/записать буфер обмена: DISPLAY=:0 xclip -o -selection clipboard / echo \"текст\" | DISPLAY=:0 xclip -selection clipboard\n"
    "5. ЗАПУСК ВЕБ-СЕРВЕРОВ И ДЕМОНОВ: Запускай только в фоне через nohup python3 app.py > /tmp/server.log 2>&1 </dev/null & и проверяй через curl.\n"
    "6. Если команда требует sudo, используй sudo -n; если прав без пароля нет, попроси пользователя выполнить её самому.\n"
    "7. Для записи файлов используй: cat << '\''EOF'\'' > путь/к/файлу\nкод\nEOF\n"
    "8. Когда задача полностью выполнена и проверена, ответь пользователю БЕЗ тега [CMD]."
)
with open(hist_file, "w", encoding="utf-8") as f:
    json.dump([{"role": "system", "content": sys_prompt}], f, ensure_ascii=False)
' "$HISTORY_FILE" "$SYS_INFO"
}

init_history
trap 'rm -f "$HISTORY_FILE" "$REPLY_FILE" "$RAW_REPLY_FILE"' EXIT

echo "------------------------------------------------------------"
echo -e "\033[1;36mOpenChat Agent (ОС + Браузер + Приложения)\033[0m | Модель: $MODEL"
echo "Команды: 'exit' — выход, '/clear' — очистить память, '--reset' — сменить ключ."
echo "------------------------------------------------------------"

send_to_ai() {
    > "$REPLY_FILE"
    > "$RAW_REPLY_FILE"
    local START_TIME=$(date +%s.%N)

    local PAYLOAD=$(python3 -c '
import sys, json
_, hist_file, model = sys.argv
with open(hist_file, "r", encoding="utf-8") as f:
    messages = json.load(f)
print(json.dumps({"model": model, "messages": messages}))
' "$HISTORY_FILE" "$MODEL")

    curl -sL --post301 --post302 --post303 "$API_URL" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $API_KEY" \
        -d "$PAYLOAD" | python3 -c '
import sys, json, re

_, hist_file, raw_out_file = sys.argv
raw = sys.stdin.read()

def format_md(text):
    text = re.sub(r"\[CMD\].*?\[/CMD\]", "", text, flags=re.DOTALL).strip()
    text = re.sub(r"```[a-zA-Z0-9_-]*\n(.*?)```", lambda m: "\n\033[0;33m" + m.group(1).strip() + "\033[0m\n", text, flags=re.DOTALL)
    text = re.sub(r"`([^`\n]+)`", r"\033[0;36m\1\033[0m", text)
    text = re.sub(r"^#{1,6}\s+(.*)$", r"\033[1;36m\1\033[0m", text, flags=re.MULTILINE)
    text = re.sub(r"\*\*(.*?)\*\*", r"\033[1m\1\033[0m", text)
    text = re.sub(r"^\s*[\*\-]\s+", "  • ", text, flags=re.MULTILINE)
    return text

try:
    data = json.loads(raw)
    if "error" in data:
        print("ОШИБКА API:", data["error"])
        sys.exit(0)
    first_choice = next(iter(data.get("choices", [])))
    content = first_choice.get("message", {}).get("content", "")
    
    with open(raw_out_file, "w", encoding="utf-8") as f:
        f.write(content)
        
    with open(hist_file, "r", encoding="utf-8") as f:
        messages = json.load(f)
    messages.append({"role": "assistant", "content": content})
    with open(hist_file, "w", encoding="utf-8") as f:
        json.dump(messages, f, ensure_ascii=False)
        
    formatted = format_md(content)
    if formatted:
        print(formatted)
except Exception as e:
    print("Ошибка ответа сервера:", raw[:300])
' "$HISTORY_FILE" "$RAW_REPLY_FILE" > "$REPLY_FILE" 2>&1 &

    local PID=$!
    while kill -0 $PID 2>/dev/null; do
        local NOW=$(date +%s.%N)
        local ELAPSED=$(awk "BEGIN {printf \"%.1f\", $NOW - $START_TIME}")
        printf "\r\033[1;33mДумает... %sс\033[0m" "$ELAPSED"
        sleep 0.1
    done
    wait $PID

    local END_TIME=$(date +%s.%N)
    local TOTAL=$(awk "BEGIN {printf \"%.1f\", $END_TIME - $START_TIME}")
    printf "\r\033[1;33mДумает: %sс\033[0m   \n" "$TOTAL"

    REPLY=$(cat "$REPLY_FILE")
    RAW_REPLY=$(cat "$RAW_REPLY_FILE")
    [[ -n "$REPLY" ]] && echo -e "\033[1;34mИИ:\033[0m $REPLY"
}

while true; do
    read -erp $'\n\033[1;32mВы:\033[0m ' USER_INPUT
    [[ "$USER_INPUT" == "exit" || "$USER_INPUT" == "quit" ]] && break
    if [[ "$USER_INPUT" == "/clear" ]]; then
        init_history
        echo "Память диалога очищена."
        continue
    fi
    [[ -z "$USER_INPUT" ]] && continue

    python3 -c '
import sys, json
_, hist_file, prompt = sys.argv
with open(hist_file, "r", encoding="utf-8") as f:
    messages = json.load(f)
messages.append({"role": "user", "content": prompt})
with open(hist_file, "w", encoding="utf-8") as f:
    json.dump(messages, f, ensure_ascii=False)
' "$HISTORY_FILE" "$USER_INPUT"

    STEP=1

    while true; do
        send_to_ai

        CMD=$(python3 -c '
import sys, re
_, text = sys.argv
m = re.search(r"\[CMD\](.*?)\[/CMD\]", text, re.DOTALL)
print(m.group(1).strip() if m else "")
' "$RAW_REPLY")

        [[ -z "$CMD" ]] && break

        echo -e "\n\033[1;35m[Авто-шаг $STEP]:\033[0m \033[0;33m$CMD\033[0m"

        if [[ "$CMD" =~ rm[[:space:]]+-rf[[:space:]]+(/|/\*|\$HOME|~)[[:space:]]*$ ]]; then
            echo -e "\033[1;31m[БЛОКИРОВКА]: Опасная команда удаления корня отклонена.\033[0m"
            break
        fi

        CMD_OUT=$(timeout 30s bash -c "$CMD" 2>&1)
        EXIT_CODE=$?

        if [[ $EXIT_CODE -eq 124 ]]; then
            CMD_OUT="$CMD_OUT\n[ОШИБКА ТАЙМАУТА 30с]: Команда не завершилась сама. Запускай GUI-приложения и серверы в фоне через nohup ... >/dev/null 2>&1 </dev/null &"
        fi

        echo -e "\033[0;37m--- Вывод (код: $EXIT_CODE) ---\n${CMD_OUT:-<выполнено>}\n------------------------\033[0m"

        python3 -c '
import sys, json
_, hist_file, out, code = sys.argv
with open(hist_file, "r", encoding="utf-8") as f:
    messages = json.load(f)
messages.append({"role": "user", "content": f"Результат команды (exit code {code}):\n{out[:4000]}"})
with open(hist_file, "w", encoding="utf-8") as f:
    json.dump(messages, f, ensure_ascii=False)
' "$HISTORY_FILE" "$CMD_OUT" "$EXIT_CODE"

        ((STEP++))
        if [[ $STEP -gt 15 ]]; then
            echo -e "\033[1;31mДостигнут лимит в 15 шагов подряд.\033[0m"
            break
        fi
    done
done
