from pathlib import Path
import argparse
from PIL import Image, ImageDraw, ImageFont


parser = argparse.ArgumentParser(description="Generate NovelCraft README diagrams")
parser.add_argument("--font", default="C:/Windows/Fonts/msyh.ttc")
parser.add_argument("--language", choices=["zh", "en"], default="zh")
args = parser.parse_args()
suffix = "-en" if args.language == "en" else ""
translations = {
    "让设定、故事与 AI 协作，在同一处展开。": "Your story, world and AI team. One workspace.",
    "项目管理 · 世界观设定 · 多智能体写作 · Prompt 模板": "Projects · Worldbuilding · AI writing teams · Prompt templates",
    "从主线大纲到章节成稿，组织属于你的创作工艺。": "Shape your writing process, from outline to finished chapters.",
    "构建故事世界": "Build your story world",
    "人物 / 势力 / 时间线 / 世界观": "Characters / Factions / Timelines / Lore",
    "定制写作工艺": "Customize your process",
    "四种正文工艺 / 多套 Prompt": "Four writing modes / Prompt variants",
    "整理与交付": "Organize and export",
    "过程档案 / EPUB / Markdown / TXT": "Archives / EPUB / Markdown / TXT",
    "一部小说的创作路径": "From an idea to a novel",
    "功能流程示意 · 具体节点按所选工艺与模型配置执行": "Workflow overview · Active stages depend on your writing mode and model setup",
    "创建书籍项目": "Create a book project",
    "书名、作者与卷章规划": "Title, author, volumes and chapters",
    "建立独立的创作资料": "Organize the book's creative material",
    "准备世界与大纲": "Build the world and outline",
    "人物、势力、世界观": "Characters, factions and world rules",
    "主线 → 分卷 → 章节大纲": "Story arc → Volume → Chapter outlines",
    "配置模型与 Prompt": "Choose models and prompts",
    "为角色选择模型": "Assign models to agent roles",
    "为工艺节点选择提示词模板": "Select a prompt template for each stage",
    "执行正文工艺": "Generate chapter prose",
    "直书 / 分段 / 优选 / 团队": "Single pass / Serial / Best-of-N / Team",
    "查看章节与阶段进度": "Track progress by chapter and stage",
    "检查与整理": "Review and organize",
    "正文质量检查、人工复核": "Prose quality checks and author review",
    "设定履历更新与过程档案": "Setting updates and generation archives",
    "导出阅读与备份": "Export and back up",
    "项目 JSON 导入导出": "Project JSON import and export",
    "审查团队为实验功能；正式采用改写前请复核内容。图中为功能示意，并非应用截图。": "AI review is experimental. Check revisions before accepting them. This is a workflow illustration, not a screenshot.",
}
output = Path(__file__).resolve().parent
width = 1600
navy = "#101C32"
muted = "#A7B8CE"
white = "#F4F8FF"
cyan = "#69DFD1"
gold = "#F1C17A"


def font(size):
    return ImageFont.truetype(args.font, size)


def label(draw, position, text, size=24, fill=white, max_width=None):
    if args.language == "en":
        text = translations.get(text, text)
    limit = max_width if max_width is not None else width - position[0] - 50
    while draw.textlength(text, font=font(size)) > limit and size > 12:
        size -= 1
    draw.text(position, text, font=font(size), fill=fill)


def canvas(height):
    image = Image.new("RGB", (width, height), navy)
    draw = ImageDraw.Draw(image)
    for row in range(height):
        fraction = row / height
        draw.line((0, row, width, row), fill=(16 + int(7 * fraction), 28 + int(12 * fraction), 50 + int(15 * fraction)))
    return image, draw


hero, draw = canvas(700)
draw.rounded_rectangle((64, 56, 449, 98), radius=21, fill="#203B4B")
label(draw, (85, 60), "FLUTTER  /  AI NOVEL WORKSPACE", 19, cyan)
label(draw, (64, 122), "NovelCraft", 90)
label(draw, (68, 251), "让设定、故事与 AI 协作，在同一处展开。", 36, max_width=1050)
label(draw, (68, 319), "项目管理 · 世界观设定 · 多智能体写作 · Prompt 模板", 25, muted, max_width=1050)
label(draw, (68, 364), "从主线大纲到章节成稿，组织属于你的创作工艺。", 25, muted, max_width=1050)
draw.rounded_rectangle((1180, 94, 1504, 413), radius=30, fill="#21314D", outline="#496384", width=2)
draw.line((1342, 127, 1342, 365), fill=gold, width=4)
for line_index, length in enumerate([96, 110, 84, 104, 72]):
    top = 164 + line_index * 34
    draw.rounded_rectangle((1206, top, 1206 + length, top + 5), radius=2, fill=muted)
    draw.rounded_rectangle((1362, top, 1362 + length, top + 5), radius=2, fill=cyan if line_index == 2 else muted)
draw.ellipse((1478, 63, 1540, 125), fill=cyan)
label(draw, (1490, 69), "AI", 28, navy)
for card_index, (heading, detail) in enumerate([
    ("构建故事世界", "人物 / 势力 / 时间线 / 世界观"),
    ("定制写作工艺", "四种正文工艺 / 多套 Prompt"),
    ("整理与交付", "过程档案 / EPUB / Markdown / TXT"),
]):
    left = 64 + card_index * 500
    draw.rounded_rectangle((left, 490, left + 470, 630), radius=18, fill="#21334D", outline="#344B67", width=2)
    label(draw, (left + 24, 510), heading, 29, cyan if card_index != 1 else gold, max_width=422)
    label(draw, (left + 24, 564), detail, 21, muted, max_width=422)
label(draw, (66, 658), "Windows / Android  ·  RWKV & multi-provider AI  ·  MIT License", 18, muted)
hero.save(output / f"novelcraft-overview{suffix}.png", optimize=True)

workflow, draw = canvas(790)
label(draw, (64, 42), "一部小说的创作路径", 44)
label(draw, (66, 112), "功能流程示意 · 具体节点按所选工艺与模型配置执行", 23, muted)
cards = [
    (64, 184, "01", "创建书籍项目", "书名、作者与卷章规划", "建立独立的创作资料"),
    (576, 184, "02", "准备世界与大纲", "人物、势力、世界观", "主线 → 分卷 → 章节大纲"),
    (1088, 184, "03", "配置模型与 Prompt", "为角色选择模型", "为工艺节点选择提示词模板"),
    (1088, 480, "04", "执行正文工艺", "直书 / 分段 / 优选 / 团队", "查看章节与阶段进度"),
    (576, 480, "05", "检查与整理", "正文质量检查、人工复核", "设定履历更新与过程档案"),
    (64, 480, "06", "导出阅读与备份", "EPUB / Markdown / TXT", "项目 JSON 导入导出"),
]
for left, top, number, heading, detail, extra in cards:
    draw.rounded_rectangle((left, top, left + 448, top + 200), radius=18, fill="#21334D", outline="#3C5472", width=2)
    label(draw, (left + 22, top + 18), number, 22, gold)
    label(draw, (left + 72, top + 15), heading, 30, max_width=352)
    label(draw, (left + 24, top + 85), detail, 23, cyan, max_width=400)
    label(draw, (left + 24, top + 132), extra, 22, muted, max_width=400)
for start, end in [((522, 284), (566, 284)), ((1034, 284), (1078, 284)), ((1312, 395), (1312, 469)), ((1078, 580), (1034, 580)), ((566, 580), (522, 580))]:
    draw.line((*start, *end), fill=gold, width=3)
    if end[0] > start[0]:
        points = [end, (end[0] - 10, end[1] - 7), (end[0] - 10, end[1] + 7)]
    elif end[0] < start[0]:
        points = [end, (end[0] + 10, end[1] - 7), (end[0] + 10, end[1] + 7)]
    else:
        points = [end, (end[0] - 7, end[1] - 10), (end[0] + 7, end[1] - 10)]
    draw.polygon(points, fill=gold)
label(draw, (66, 730), "审查团队为实验功能；正式采用改写前请复核内容。图中为功能示意，并非应用截图。", 21, muted)
workflow.save(output / f"writing-workflow{suffix}.png", optimize=True)
