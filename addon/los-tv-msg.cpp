/*
 * los-tv-msg — статус установки на экране recovery (с прокруткой истории).
 *
 * Используется установщиком проприетарных компонентов: меню recovery
 * останавливается (`stop recovery`), чтобы освободить DRM/fb, после чего
 * эта утилита рисует текст через minui.
 *
 * Каждый вызов ДОБАВЛЯЕТ сообщение в историю (/tmp/los-tv-msg.history) и
 * перерисовывает экран, показывая последние строки, которые помещаются.
 * Так ранние сообщения не затираются и их можно прочитать позже.
 *
 * Оформление: заголовок шага — белый жирный с префиксом ">> ", детали —
 * серые с отступом, между шагами пустая строка. Длинные строки переносятся
 * по словам, чтобы не обрезались за краем экрана.
 *
 * Аргументы:
 *   --reset        очистить историю перед добавлением сообщения;
 *   <title>        первая строка — заголовок шага (жирный);
 *   <detail>...    остальные строки — детали.
 *
 * Код возврата 0 при успехе.
 */

#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include <string>
#include <vector>

#include <minui/minui.h>

namespace {

constexpr const char* kHistoryPath = "/tmp/los-tv-msg.history";

// Ограничение, чтобы файл не рос бесконечно при долгой установке.
constexpr size_t kMaxHistoryLines = 300;

constexpr int kMarginX = 64;
constexpr int kMarginRight = 48;
constexpr int kMarginTop = 64;
constexpr int kMarginBottom = 40;
constexpr int kLineGap = 6;

// Маркеры строк в файле истории: заголовок шага / деталь.
constexpr char kTitleMark = '\x01';
constexpr char kDetailMark = '\x02';

constexpr const char* kTitlePrefix = ">> ";
constexpr const char* kDetailPrefix = "   ";

struct Line {
    bool title;
    std::string text;
};

// Одна строка, готовая к отрисовке (после переноса).
struct RenderLine {
    bool title;
    std::string text;  // уже с префиксом/отступом
};

std::vector<Line> LoadHistory() {
    std::vector<Line> lines;

    FILE* f = fopen(kHistoryPath, "re");
    if (f == nullptr) return lines;

    char buf[2048];
    while (fgets(buf, sizeof(buf), f) != nullptr) {
        size_t len = strlen(buf);
        while (len > 0 && (buf[len - 1] == '\n' || buf[len - 1] == '\r')) {
            buf[--len] = '\0';
        }

        Line line;
        if (len > 0 && (buf[0] == kTitleMark || buf[0] == kDetailMark)) {
            line.title = (buf[0] == kTitleMark);
            line.text = buf + 1;
        } else {
            line.title = false;
            line.text = buf;
        }
        lines.push_back(std::move(line));
    }

    fclose(f);
    return lines;
}

void SaveHistory(const std::vector<Line>& lines) {
    FILE* f = fopen(kHistoryPath, "we");
    if (f == nullptr) return;

    for (const auto& line : lines) {
        fputc(line.title ? kTitleMark : kDetailMark, f);
        fputs(line.text.c_str(), f);
        fputc('\n', f);
    }
    fclose(f);
}

void AppendHistory(const std::vector<Line>& entry) {
    std::vector<Line> lines = LoadHistory();
    for (const auto& line : entry) lines.push_back(line);

    if (lines.size() > kMaxHistoryLines) {
        lines.erase(lines.begin(), lines.begin() + (lines.size() - kMaxHistoryLines));
    }

    SaveHistory(lines);
}

// Перенос одной строки по словам. prefix уже включён в первую строку,
// продолжения выравниваются пробелами по его длине.
std::vector<std::string> WrapText(const GRFont* font, const std::string& text,
                                  const std::string& prefix, int max_width) {
    std::vector<std::string> out;

    std::string rest = prefix + text;
    const std::string indent(prefix.size(), ' ');

    while (true) {
        if (gr_measure(font, rest.c_str()) <= max_width) {
            out.push_back(rest);
            break;
        }

        // Ищем максимальный префикс, который ещё влезает.
        size_t cut = 0;
        for (size_t i = 1; i <= rest.size(); i++) {
            if (gr_measure(font, rest.substr(0, i).c_str()) > max_width) break;
            cut = i;
        }
        if (cut == 0) cut = 1;

        // Отступаем до последнего пробела, чтобы не рвать слова.
        size_t space = rest.rfind(' ', cut);
        if (space != std::string::npos && space >= indent.size()) {
            cut = space;
        }

        out.push_back(rest.substr(0, cut));

        std::string tail = rest.substr(cut);
        size_t first_non_space = tail.find_first_not_of(' ');
        if (first_non_space == std::string::npos) break;
        rest = indent + tail.substr(first_non_space);
    }

    return out;
}

std::vector<RenderLine> BuildRenderLines(const GRFont* font, int max_width,
                                         const std::vector<Line>& lines) {
    std::vector<RenderLine> out;

    for (const auto& line : lines) {
        const char* prefix = line.title ? kTitlePrefix : kDetailPrefix;
        for (const auto& wrapped : WrapText(font, line.text, prefix, max_width)) {
            out.push_back(RenderLine{line.title, wrapped});
        }
    }

    return out;
}

}  // namespace

int main(int argc, char** argv) {
    bool reset = false;
    int first = 1;
    if (argc > 1 && strcmp(argv[1], "--reset") == 0) {
        reset = true;
        first = 2;
    }

    if (reset) unlink(kHistoryPath);

    if (argc > first) {
        std::vector<Line> entry;
        for (int i = first; i < argc; i++) {
            entry.push_back(Line{i == first, argv[i]});
        }
        AppendHistory(entry);
    }

    std::vector<Line> lines = LoadHistory();

    if (gr_init() != 0) {
        fprintf(stderr, "los-tv-msg: gr_init failed\n");
        return 1;
    }

    const GRFont* font = gr_sys_font();
    if (font == nullptr) {
        fprintf(stderr, "los-tv-msg: no font\n");
        gr_exit();
        return 1;
    }

    int char_w = 0, char_h = 0;
    gr_font_size(font, &char_w, &char_h);
    if (char_h <= 0) char_h = 16;

    gr_color(0, 0, 0, 255);
    gr_clear();

    const int max_width = gr_fb_width() - kMarginX - kMarginRight;
    std::vector<RenderLine> render = BuildRenderLines(font, max_width, lines);

    const int line_h = char_h + kLineGap;
    const int title_gap = char_h;

    // Идём с конца и набираем строки, пока влезают по высоте (с учётом
    // дополнительного отступа перед заголовками).
    const int usable = gr_fb_height() - kMarginTop - kMarginBottom;
    size_t start = render.size();
    int used = 0;
    while (start > 0) {
        size_t idx = start - 1;
        int add = line_h;
        if (render[idx].title && idx > 0) add += title_gap;
        if (used + add > usable) break;
        used += add;
        start = idx;
    }
    if (start == render.size() && !render.empty()) {
        start = render.size() - 1;
    }

    int y = kMarginTop;
    for (size_t i = start; i < render.size(); i++) {
        if (render[i].title && i > start) {
            y += title_gap;
        }

        if (render[i].title) {
            gr_color(255, 255, 255, 255);
        } else {
            gr_color(190, 190, 190, 255);
        }

        gr_text(font, kMarginX, y, render[i].text.c_str(), render[i].title);
        y += line_h;
    }
    gr_flip();

    /* Не вызываем gr_exit(): экран должен остаться как есть, а повторный
     * вызов утилиты всё равно переинициализирует backend. */
    return 0;
}
