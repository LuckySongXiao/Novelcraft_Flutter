# -*- coding: utf-8 -*-
"""Restore the built-in sample project and add a few demo chapters.

Only touches the project 'demo-xuanqiong' (the app's own seeded sample) so the
README screenshots can show populated pages. Run only while the app is closed.
"""
import sqlite3
import time

DB = r"C:\Users\Administrator\Documents\novelcraft.sqlite"
PROJECT_ID = "demo-xuanqiong"
VOLUME_ID = "demo-xuanqiong-v1"

CHAPTERS = [
    (
        "第一章 雪夜惊变",
        "玄穹山剑宗一夜覆灭，少年叶辰在雪地里捡到半截断剑。",
        "雪落了三日，玄穹山的石阶被冻成一条白练。\n"
        "叶辰提着一盏将熄的油灯往上走，耳边只剩下风穿过剑冢的呜咽。他记得师父说过，"
        "剑宗的山门从不落雪——如今这句话和山门一起碎了。\n"
        "石阶尽头，一柄断剑插在冻土里。他伸手去拔，指尖刚触到剑身，"
        "便听见一个极轻的声音在识海里响起：\n"
        "“你终于来了。”",
    ),
    (
        "第二章 断剑残魂",
        "断剑中沉睡着一缕残魂，自称玄穹剑主。",
        "残魂没有形体，只在识海里凝成一道淡青色的虚影。\n"
        "“我教不了你长生，也教不了你无敌。”它说，“我只能教你怎么把剑握住。”\n"
        "叶辰望着自己冻裂的手掌，问了第一个问题：“握住之后呢？”\n"
        "残魂沉默了很久，答：“握住之后，才有资格谈别的。”",
    ),
    (
        "第三章 拜入剑宗",
        "叶辰带着断剑南下，投入青冥剑宗外门。",
        "青冥剑宗的验剑石前，队伍排到了山门外。\n"
        "轮到叶辰时，他把断剑放在石上。石面纹丝不动，连一丝灵光都没泛起。"
        "周围的哄笑声里，负责登记的执事摇了摇头，在名册上写下“外门·杂役”。\n"
        "叶辰收起断剑，转身走进挑水的那条路。他没有回头。",
    ),
    (
        "第四章 玄穹诀",
        "残魂传下《玄穹诀》第一重，叶辰在杂役房外的雪地里炼剑。",
        "《玄穹诀》第一重只有八个字：以身为鞘，以念为锋。\n"
        "叶辰不懂。他只知道每天挑完三十担水，天就黑了；天黑之后，"
        "他可以在柴房后面练两个时辰的挥剑。\n"
        "第三十七个夜里，他挥到第七百二十一次时，断剑忽然自发地亮了一下。\n"
        "残魂在识海里“咦”了一声。",
    ),
    (
        "第五章 试剑大会",
        "外门试剑，叶辰连胜三场，第一次被人记住名字。",
        "试剑台边挤满了人。没人认识叶辰，直到他第四场站上台。\n"
        "对手是外门排名第九的周焕。三招之后，周焕的剑落地。\n"
        "台下一静，随即炸开。执事重新翻开名册，在“外门·杂役”四个字旁边，"
        "补了一笔。\n"
        "那一刻叶辰才明白，师父说的“握住之后才有资格谈别的”，是什么意思。",
    ),
    (
        "第六章 妖皇将至",
        "北境传来消息：妖皇破关，三宗会盟。",
        "消息是一支断箭送来的，箭杆上缠着青冥、玄穹与太虚三家的印记。\n"
        "妖皇破关，北境十七城一夜尽墨。三宗不得不会盟。\n"
        "叶辰站在人群最外围，听着长老们争论由谁领队。他握紧了怀里的断剑——"
        "那截冰凉的铁，此刻竟有些烫。",
    ),
]


def main() -> None:
    now = int(time.time())
    conn = sqlite3.connect(DB)
    cur = conn.cursor()

    cur.execute(
        "UPDATE projects SET is_deleted=0, deleted_at=NULL, updated_at=? WHERE id=?",
        (now, PROJECT_ID),
    )
    print("project restored:", cur.rowcount)

    cur.execute(
        "DELETE FROM chapters WHERE project_id=? AND id LIKE 'demo-cap%'",
        (PROJECT_ID,),
    )
    print("old demo chapters removed:", cur.rowcount)

    for index, (title, summary, content) in enumerate(CHAPTERS, start=1):
        cur.execute(
            """
            INSERT INTO chapters (
                id, created_at, updated_at, is_deleted, version,
                title, content, summary, order_index, status,
                volume_id, project_id, word_count, version_number
            ) VALUES (?, ?, ?, 0, 0, ?, ?, ?, ?, 'Draft', ?, ?, ?, 1)
            """,
            (
                f"demo-cap{index:02d}",
                now,
                now,
                title,
                content,
                summary,
                index,
                VOLUME_ID,
                PROJECT_ID,
                len(content),
            ),
        )
    print("chapters inserted:", len(CHAPTERS))

    conn.commit()
    cur.execute(
        "SELECT count(*) FROM chapters WHERE project_id=? AND is_deleted=0",
        (PROJECT_ID,),
    )
    print("visible chapters now:", cur.fetchone()[0])
    conn.close()


if __name__ == "__main__":
    main()
