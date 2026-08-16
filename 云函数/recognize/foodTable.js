// AUTO-GENERATED from AIA/AIA/NutritionLibrary.swift by gen-food-table.mjs — 不要手改。
// 云端 queryFood 查表优先，命中即返确定值，避免对常见食物反复 LLM 估算导致数值漂移。
const SEED_VERSION = 2;
const FOOD_TABLE = {
  "米饭": {
    "kcal": 116,
    "protein": 2.6,
    "carbs": 25.9,
    "fat": 0.3,
    "fiber": 0.3,
    "sugar": 0.1,
    "sodium": 1
  },
  "白米饭": {
    "kcal": 116,
    "protein": 2.6,
    "carbs": 25.9,
    "fat": 0.3,
    "fiber": 0.3,
    "sugar": 0.1,
    "sodium": 1
  },
  "大米": {
    "kcal": 346,
    "protein": 7.4,
    "carbs": 77.9,
    "fat": 0.8,
    "fiber": 0.7,
    "sugar": 0.1,
    "sodium": 0
  },
  "糙米": {
    "kcal": 368,
    "protein": 7.9,
    "carbs": 76.7,
    "fat": 2.9,
    "fiber": 1.8,
    "sugar": 0.4,
    "sodium": 2
  },
  "黑米": {
    "kcal": 341,
    "protein": 8.9,
    "carbs": 72.1,
    "fat": 2.5,
    "fiber": 2.8,
    "sugar": 0.8,
    "sodium": 4
  },
  "糯米": {
    "kcal": 350,
    "protein": 7.3,
    "carbs": 77.7,
    "fat": 1,
    "fiber": 0.8,
    "sugar": 0.6,
    "sodium": 1
  },
  "小米": {
    "kcal": 361,
    "protein": 9,
    "carbs": 75.1,
    "fat": 3.1,
    "fiber": 1.6,
    "sugar": 1.6,
    "sodium": 4
  },
  "粥": {
    "kcal": 46,
    "protein": 1.1,
    "carbs": 9.9,
    "fat": 0.3,
    "fiber": 0.1,
    "sugar": 0.1,
    "sodium": 0
  },
  "小米粥": {
    "kcal": 46,
    "protein": 1.1,
    "carbs": 9.9,
    "fat": 0.3,
    "fiber": 0.1,
    "sugar": 0.1,
    "sodium": 0
  },
  "八宝粥": {
    "kcal": 70,
    "protein": 2,
    "carbs": 14,
    "fat": 0.5,
    "fiber": 1,
    "sugar": 3,
    "sodium": 5
  },
  "馒头": {
    "kcal": 223,
    "protein": 7,
    "carbs": 47,
    "fat": 1.1,
    "fiber": 1,
    "sugar": 1,
    "sodium": 165
  },
  "花卷": {
    "kcal": 214,
    "protein": 6.4,
    "carbs": 45,
    "fat": 1.3,
    "fiber": 1.5,
    "sugar": 2,
    "sodium": 180
  },
  "烙饼": {
    "kcal": 255,
    "protein": 7.5,
    "carbs": 52.9,
    "fat": 2.3,
    "fiber": 1.9,
    "sugar": 1,
    "sodium": 200
  },
  "烧饼": {
    "kcal": 293,
    "protein": 8,
    "carbs": 56,
    "fat": 6,
    "fiber": 2,
    "sugar": 2,
    "sodium": 280
  },
  "煎饼": {
    "kcal": 333,
    "protein": 9,
    "carbs": 62,
    "fat": 3,
    "fiber": 1.5,
    "sugar": 2,
    "sodium": 250
  },
  "葱油饼": {
    "kcal": 400,
    "protein": 8,
    "carbs": 48,
    "fat": 20,
    "fiber": 1.5,
    "sugar": 2,
    "sodium": 400
  },
  "手抓饼": {
    "kcal": 450,
    "protein": 8,
    "carbs": 45,
    "fat": 27,
    "fiber": 1.5,
    "sugar": 1.5,
    "sodium": 500
  },
  "油条": {
    "kcal": 388,
    "protein": 6.9,
    "carbs": 51,
    "fat": 17,
    "fiber": 0.9,
    "sugar": 1.5,
    "sodium": 585
  },
  "面条": {
    "kcal": 286,
    "protein": 8.5,
    "carbs": 61,
    "fat": 1,
    "fiber": 0.9,
    "sugar": 0.5,
    "sodium": 3
  },
  "煮面条": {
    "kcal": 110,
    "protein": 4,
    "carbs": 22,
    "fat": 0.4,
    "fiber": 0.5,
    "sugar": 0.3,
    "sodium": 2
  },
  "挂面": {
    "kcal": 355,
    "protein": 10.3,
    "carbs": 75,
    "fat": 1,
    "fiber": 1,
    "sugar": 1,
    "sodium": 200
  },
  "方便面": {
    "kcal": 472,
    "protein": 9.5,
    "carbs": 61,
    "fat": 21,
    "fiber": 1,
    "sugar": 1.5,
    "sodium": 1100
  },
  "粉丝": {
    "kcal": 338,
    "protein": 0.8,
    "carbs": 83.7,
    "fat": 0.2,
    "fiber": 0.5,
    "sugar": 0.3,
    "sodium": 9
  },
  "粉条": {
    "kcal": 339,
    "protein": 0.5,
    "carbs": 84,
    "fat": 0.1,
    "fiber": 0.6,
    "sugar": 0.4,
    "sodium": 10
  },
  "米粉": {
    "kcal": 346,
    "protein": 7.3,
    "carbs": 77.5,
    "fat": 0.9,
    "fiber": 0.5,
    "sugar": 0.5,
    "sodium": 8
  },
  "年糕": {
    "kcal": 156,
    "protein": 3.3,
    "carbs": 34,
    "fat": 0.4,
    "fiber": 0.8,
    "sugar": 1,
    "sodium": 5
  },
  "面包": {
    "kcal": 265,
    "protein": 9,
    "carbs": 49,
    "fat": 5.1,
    "fiber": 2.7,
    "sugar": 5,
    "sodium": 472
  },
  "吐司": {
    "kcal": 265,
    "protein": 9,
    "carbs": 49,
    "fat": 5.1,
    "fiber": 2.7,
    "sugar": 5,
    "sodium": 472
  },
  "全麦面包": {
    "kcal": 250,
    "protein": 9,
    "carbs": 46,
    "fat": 3.4,
    "fiber": 6,
    "sugar": 5,
    "sodium": 400
  },
  "法棍": {
    "kcal": 277,
    "protein": 8.5,
    "carbs": 56,
    "fat": 1.2,
    "fiber": 2.7,
    "sugar": 1.5,
    "sodium": 480
  },
  "包子": {
    "kcal": 220,
    "protein": 7,
    "carbs": 40,
    "fat": 1,
    "fiber": 1,
    "sugar": 2,
    "sodium": 240
  },
  "饺子": {
    "kcal": 200,
    "protein": 8,
    "carbs": 26,
    "fat": 7,
    "fiber": 0.8,
    "sugar": 1,
    "sodium": 350
  },
  "馄饨": {
    "kcal": 200,
    "protein": 8,
    "carbs": 24,
    "fat": 7,
    "fiber": 0.8,
    "sugar": 1,
    "sodium": 350
  },
  "烧麦": {
    "kcal": 220,
    "protein": 6,
    "carbs": 38,
    "fat": 5,
    "fiber": 1,
    "sugar": 2,
    "sodium": 300
  },
  "春卷": {
    "kcal": 250,
    "protein": 6,
    "carbs": 32,
    "fat": 10,
    "fiber": 1.5,
    "sugar": 2,
    "sodium": 350
  },
  "燕麦": {
    "kcal": 367,
    "protein": 15,
    "carbs": 61,
    "fat": 7,
    "fiber": 10.6,
    "sugar": 0,
    "sodium": 0
  },
  "燕麦粥": {
    "kcal": 68,
    "protein": 2.4,
    "carbs": 12,
    "fat": 1.2,
    "fiber": 1.7,
    "sugar": 0.3,
    "sodium": 2
  },
  "麦片": {
    "kcal": 370,
    "protein": 13,
    "carbs": 60,
    "fat": 8,
    "fiber": 9,
    "sugar": 12,
    "sodium": 300
  },
  "荞麦": {
    "kcal": 337,
    "protein": 9.3,
    "carbs": 66.7,
    "fat": 2.7,
    "fiber": 4.5,
    "sugar": 0.9,
    "sodium": 3
  },
  "薏米": {
    "kcal": 361,
    "protein": 12.8,
    "carbs": 71.1,
    "fat": 3.3,
    "fiber": 2,
    "sugar": 0.5,
    "sodium": 3
  },
  "藜麦": {
    "kcal": 368,
    "protein": 14.1,
    "carbs": 64.2,
    "fat": 6.1,
    "fiber": 7,
    "sugar": 1,
    "sodium": 7
  },
  "红薯": {
    "kcal": 99,
    "protein": 1.1,
    "carbs": 24,
    "fat": 0.2,
    "fiber": 1.6,
    "sugar": 4.2,
    "sodium": 28
  },
  "紫薯": {
    "kcal": 82,
    "protein": 1.4,
    "carbs": 19,
    "fat": 0.2,
    "fiber": 2,
    "sugar": 5,
    "sodium": 50
  },
  "土豆": {
    "kcal": 77,
    "protein": 2,
    "carbs": 17,
    "fat": 0.1,
    "fiber": 0.6,
    "sugar": 0.3,
    "sodium": 2
  },
  "马铃薯": {
    "kcal": 77,
    "protein": 2,
    "carbs": 17,
    "fat": 0.1,
    "fiber": 0.6,
    "sugar": 0.3,
    "sodium": 2
  },
  "山药": {
    "kcal": 57,
    "protein": 1.9,
    "carbs": 12.4,
    "fat": 0.2,
    "fiber": 0.8,
    "sugar": 1,
    "sodium": 2
  },
  "芋头": {
    "kcal": 79,
    "protein": 2.2,
    "carbs": 17.1,
    "fat": 0.2,
    "fiber": 1,
    "sugar": 1,
    "sodium": 2
  },
  "南瓜": {
    "kcal": 26,
    "protein": 1,
    "carbs": 5.3,
    "fat": 0.1,
    "fiber": 0.5,
    "sugar": 2,
    "sodium": 1
  },
  "玉米": {
    "kcal": 106,
    "protein": 4,
    "carbs": 22,
    "fat": 1.2,
    "fiber": 2.7,
    "sugar": 3.2,
    "sodium": 1
  },
  "糯玉米": {
    "kcal": 140,
    "protein": 4,
    "carbs": 30,
    "fat": 1.5,
    "fiber": 3,
    "sugar": 5,
    "sodium": 2
  },
  "凉皮": {
    "kcal": 117,
    "protein": 3,
    "carbs": 25,
    "fat": 0.5,
    "fiber": 0.8,
    "sugar": 0.5,
    "sodium": 120
  },
  "肠粉": {
    "kcal": 110,
    "protein": 4,
    "carbs": 23,
    "fat": 0.5,
    "fiber": 0.5,
    "sugar": 1,
    "sodium": 150
  },
  "意大利面": {
    "kcal": 359,
    "protein": 12.8,
    "carbs": 71,
    "fat": 1.7,
    "fiber": 3.2,
    "sugar": 1.8,
    "sodium": 6
  },
  "通心粉": {
    "kcal": 359,
    "protein": 12.8,
    "carbs": 71,
    "fat": 1.7,
    "fiber": 3.2,
    "sugar": 1.8,
    "sodium": 6
  },
  "鸡胸肉": {
    "kcal": 133,
    "protein": 24,
    "carbs": 0,
    "fat": 5,
    "fiber": 0,
    "sugar": 0,
    "sodium": 45
  },
  "鸡腿": {
    "kcal": 181,
    "protein": 19,
    "carbs": 0,
    "fat": 11,
    "fiber": 0,
    "sugar": 0,
    "sodium": 76
  },
  "鸡肉": {
    "kcal": 167,
    "protein": 19,
    "carbs": 0,
    "fat": 9,
    "fiber": 0,
    "sugar": 0,
    "sodium": 54
  },
  "鸡翅": {
    "kcal": 194,
    "protein": 17,
    "carbs": 0,
    "fat": 14,
    "fiber": 0,
    "sugar": 0,
    "sodium": 70
  },
  "鸡爪": {
    "kcal": 254,
    "protein": 23,
    "carbs": 0,
    "fat": 17,
    "fiber": 0,
    "sugar": 0,
    "sodium": 70
  },
  "鸭肉": {
    "kcal": 240,
    "protein": 15,
    "carbs": 0,
    "fat": 19,
    "fiber": 0,
    "sugar": 0,
    "sodium": 60
  },
  "鸭腿": {
    "kcal": 210,
    "protein": 16,
    "carbs": 0,
    "fat": 16,
    "fiber": 0,
    "sugar": 0,
    "sodium": 80
  },
  "牛肉": {
    "kcal": 125,
    "protein": 20,
    "carbs": 0,
    "fat": 4.2,
    "fiber": 0,
    "sugar": 0,
    "sodium": 53
  },
  "牛里脊": {
    "kcal": 107,
    "protein": 22,
    "carbs": 0,
    "fat": 2,
    "fiber": 0,
    "sugar": 0,
    "sodium": 50
  },
  "牛腩": {
    "kcal": 332,
    "protein": 18,
    "carbs": 0,
    "fat": 29,
    "fiber": 0,
    "sugar": 0,
    "sodium": 60
  },
  "肥牛": {
    "kcal": 250,
    "protein": 18,
    "carbs": 0,
    "fat": 20,
    "fiber": 0,
    "sugar": 0,
    "sodium": 60
  },
  "羊肉": {
    "kcal": 203,
    "protein": 19,
    "carbs": 0,
    "fat": 14,
    "fiber": 0,
    "sugar": 0,
    "sodium": 80
  },
  "羊排": {
    "kcal": 294,
    "protein": 18,
    "carbs": 0,
    "fat": 25,
    "fiber": 0,
    "sugar": 0,
    "sodium": 80
  },
  "瘦肉": {
    "kcal": 143,
    "protein": 20,
    "carbs": 1.5,
    "fat": 6,
    "fiber": 0,
    "sugar": 0,
    "sodium": 56
  },
  "猪肉": {
    "kcal": 395,
    "protein": 13,
    "carbs": 1.5,
    "fat": 37,
    "fiber": 0,
    "sugar": 0,
    "sodium": 57
  },
  "五花肉": {
    "kcal": 508,
    "protein": 7,
    "carbs": 0,
    "fat": 53,
    "fiber": 0,
    "sugar": 0,
    "sodium": 65
  },
  "排骨": {
    "kcal": 264,
    "protein": 17,
    "carbs": 0,
    "fat": 22,
    "fiber": 0,
    "sugar": 0,
    "sodium": 60
  },
  "猪蹄": {
    "kcal": 260,
    "protein": 23,
    "carbs": 0,
    "fat": 18,
    "fiber": 0,
    "sugar": 0,
    "sodium": 60
  },
  "猪肝": {
    "kcal": 129,
    "protein": 19.3,
    "carbs": 5,
    "fat": 3.5,
    "fiber": 0,
    "sugar": 0,
    "sodium": 70
  },
  "香肠": {
    "kcal": 290,
    "protein": 12,
    "carbs": 10,
    "fat": 23,
    "fiber": 0,
    "sugar": 1,
    "sodium": 1200
  },
  "培根": {
    "kcal": 400,
    "protein": 28,
    "carbs": 1.4,
    "fat": 32,
    "fiber": 0,
    "sugar": 0,
    "sodium": 1100
  },
  "火腿": {
    "kcal": 320,
    "protein": 16,
    "carbs": 2,
    "fat": 28,
    "fiber": 1,
    "sugar": 0,
    "sodium": 1200
  },
  "午餐肉": {
    "kcal": 229,
    "protein": 9,
    "carbs": 12,
    "fat": 15,
    "fiber": 0,
    "sugar": 1,
    "sodium": 900
  },
  "鸡蛋": {
    "kcal": 144,
    "protein": 13,
    "carbs": 1.1,
    "fat": 9,
    "fiber": 0,
    "sugar": 0.4,
    "sodium": 131
  },
  "鸭蛋": {
    "kcal": 180,
    "protein": 12.6,
    "carbs": 3.1,
    "fat": 13,
    "fiber": 0,
    "sugar": 0.5,
    "sodium": 106
  },
  "鹌鹑蛋": {
    "kcal": 160,
    "protein": 12.8,
    "carbs": 2.4,
    "fat": 11,
    "fiber": 0,
    "sugar": 0.4,
    "sodium": 130
  },
  "皮蛋": {
    "kcal": 171,
    "protein": 14,
    "carbs": 4.5,
    "fat": 10,
    "fiber": 0,
    "sugar": 0.5,
    "sodium": 540
  },
  "咸鸭蛋": {
    "kcal": 190,
    "protein": 12.7,
    "carbs": 6.3,
    "fat": 12.7,
    "fiber": 0,
    "sugar": 0.5,
    "sodium": 1300
  },
  "鱼肉": {
    "kcal": 105,
    "protein": 18,
    "carbs": 0,
    "fat": 3.5,
    "fiber": 0,
    "sugar": 0,
    "sodium": 50
  },
  "鲈鱼": {
    "kcal": 105,
    "protein": 18,
    "carbs": 0,
    "fat": 3.5,
    "fiber": 0,
    "sugar": 0,
    "sodium": 50
  },
  "鲫鱼": {
    "kcal": 108,
    "protein": 17.1,
    "carbs": 3.8,
    "fat": 2.7,
    "fiber": 0,
    "sugar": 0,
    "sodium": 70
  },
  "草鱼": {
    "kcal": 113,
    "protein": 16.6,
    "carbs": 0,
    "fat": 5.2,
    "fiber": 0,
    "sugar": 0,
    "sodium": 46
  },
  "带鱼": {
    "kcal": 127,
    "protein": 17.7,
    "carbs": 3.1,
    "fat": 4.9,
    "fiber": 0,
    "sugar": 0,
    "sodium": 150
  },
  "黄花鱼": {
    "kcal": 97,
    "protein": 17.7,
    "carbs": 0,
    "fat": 2.5,
    "fiber": 0,
    "sugar": 0,
    "sodium": 120
  },
  "三文鱼": {
    "kcal": 208,
    "protein": 20,
    "carbs": 0,
    "fat": 13,
    "fiber": 0,
    "sugar": 0,
    "sodium": 47
  },
  "金枪鱼": {
    "kcal": 132,
    "protein": 28,
    "carbs": 0,
    "fat": 1.3,
    "fiber": 0,
    "sugar": 0,
    "sodium": 40
  },
  "鳕鱼": {
    "kcal": 88,
    "protein": 20,
    "carbs": 0,
    "fat": 0.7,
    "fiber": 0,
    "sugar": 0,
    "sodium": 70
  },
  "龙利鱼": {
    "kcal": 90,
    "protein": 18,
    "carbs": 0,
    "fat": 1.8,
    "fiber": 0,
    "sugar": 0,
    "sodium": 80
  },
  "巴沙鱼": {
    "kcal": 90,
    "protein": 15,
    "carbs": 0,
    "fat": 3,
    "fiber": 0,
    "sugar": 0,
    "sodium": 70
  },
  "秋刀鱼": {
    "kcal": 190,
    "protein": 18,
    "carbs": 0,
    "fat": 13,
    "fiber": 0,
    "sugar": 0,
    "sodium": 100
  },
  "虾": {
    "kcal": 93,
    "protein": 18,
    "carbs": 1,
    "fat": 1.4,
    "fiber": 0,
    "sugar": 0,
    "sodium": 224
  },
  "基围虾": {
    "kcal": 101,
    "protein": 18.2,
    "carbs": 1.5,
    "fat": 1.4,
    "fiber": 0,
    "sugar": 0,
    "sodium": 120
  },
  "龙虾": {
    "kcal": 90,
    "protein": 18,
    "carbs": 0,
    "fat": 1,
    "fiber": 0,
    "sugar": 0,
    "sodium": 200
  },
  "蟹": {
    "kcal": 95,
    "protein": 17.5,
    "carbs": 2.3,
    "fat": 2.6,
    "fiber": 0,
    "sugar": 0,
    "sodium": 270
  },
  "螃蟹": {
    "kcal": 95,
    "protein": 17.5,
    "carbs": 2.3,
    "fat": 2.6,
    "fiber": 0,
    "sugar": 0,
    "sodium": 270
  },
  "扇贝": {
    "kcal": 60,
    "protein": 11.1,
    "carbs": 2.6,
    "fat": 0.6,
    "fiber": 0,
    "sugar": 0,
    "sodium": 280
  },
  "生蚝": {
    "kcal": 57,
    "protein": 10.9,
    "carbs": 0,
    "fat": 1.5,
    "fiber": 0,
    "sugar": 0,
    "sodium": 200
  },
  "牡蛎": {
    "kcal": 57,
    "protein": 10.9,
    "carbs": 0,
    "fat": 1.5,
    "fiber": 0,
    "sugar": 0,
    "sodium": 200
  },
  "鱿鱼": {
    "kcal": 92,
    "protein": 17,
    "carbs": 0,
    "fat": 1.4,
    "fiber": 0,
    "sugar": 0,
    "sodium": 150
  },
  "墨鱼": {
    "kcal": 82,
    "protein": 17,
    "carbs": 0,
    "fat": 0.8,
    "fiber": 0,
    "sugar": 0,
    "sodium": 150
  },
  "蛤蜊": {
    "kcal": 62,
    "protein": 10.1,
    "carbs": 2.5,
    "fat": 1.1,
    "fiber": 0,
    "sugar": 0,
    "sodium": 320
  },
  "海参": {
    "kcal": 78,
    "protein": 16.5,
    "carbs": 0.9,
    "fat": 0.2,
    "fiber": 0,
    "sugar": 0,
    "sodium": 500
  },
  "鲍鱼": {
    "kcal": 84,
    "protein": 12.6,
    "carbs": 0,
    "fat": 0.8,
    "fiber": 0,
    "sugar": 0,
    "sodium": 230
  },
  "西兰花": {
    "kcal": 34,
    "protein": 2.8,
    "carbs": 7,
    "fat": 0.4,
    "fiber": 2.6,
    "sugar": 1.7,
    "sodium": 33
  },
  "花菜": {
    "kcal": 24,
    "protein": 2.1,
    "carbs": 4.6,
    "fat": 0.2,
    "fiber": 1.6,
    "sugar": 1.2,
    "sodium": 20
  },
  "菜花": {
    "kcal": 24,
    "protein": 2.1,
    "carbs": 4.6,
    "fat": 0.2,
    "fiber": 1.6,
    "sugar": 1.2,
    "sodium": 20
  },
  "西红柿": {
    "kcal": 18,
    "protein": 0.9,
    "carbs": 3.9,
    "fat": 0.2,
    "fiber": 0.5,
    "sugar": 2.6,
    "sodium": 5
  },
  "番茄": {
    "kcal": 18,
    "protein": 0.9,
    "carbs": 3.9,
    "fat": 0.2,
    "fiber": 0.5,
    "sugar": 2.6,
    "sodium": 5
  },
  "黄瓜": {
    "kcal": 16,
    "protein": 0.8,
    "carbs": 2.9,
    "fat": 0.2,
    "fiber": 0.5,
    "sugar": 1.7,
    "sodium": 2
  },
  "菠菜": {
    "kcal": 23,
    "protein": 2.9,
    "carbs": 3.6,
    "fat": 0.4,
    "fiber": 2.2,
    "sugar": 0.4,
    "sodium": 79
  },
  "生菜": {
    "kcal": 15,
    "protein": 1.4,
    "carbs": 2.9,
    "fat": 0.2,
    "fiber": 1,
    "sugar": 0.5,
    "sodium": 28
  },
  "白菜": {
    "kcal": 17,
    "protein": 1.5,
    "carbs": 3.2,
    "fat": 0.1,
    "fiber": 0.9,
    "sugar": 1.5,
    "sodium": 57
  },
  "小白菜": {
    "kcal": 15,
    "protein": 1.5,
    "carbs": 2.7,
    "fat": 0.3,
    "fiber": 1.1,
    "sugar": 1,
    "sodium": 73
  },
  "油菜": {
    "kcal": 23,
    "protein": 1.8,
    "carbs": 3.8,
    "fat": 0.5,
    "fiber": 1.1,
    "sugar": 1,
    "sodium": 55
  },
  "空心菜": {
    "kcal": 20,
    "protein": 2.2,
    "carbs": 3.6,
    "fat": 0.3,
    "fiber": 1.4,
    "sugar": 0.8,
    "sodium": 40
  },
  "卷心菜": {
    "kcal": 24,
    "protein": 1.5,
    "carbs": 4.6,
    "fat": 0.2,
    "fiber": 1,
    "sugar": 2.2,
    "sodium": 27
  },
  "包菜": {
    "kcal": 24,
    "protein": 1.5,
    "carbs": 4.6,
    "fat": 0.2,
    "fiber": 1,
    "sugar": 2.2,
    "sodium": 27
  },
  "紫甘蓝": {
    "kcal": 31,
    "protein": 1.4,
    "carbs": 6.2,
    "fat": 0.2,
    "fiber": 1.5,
    "sugar": 3,
    "sodium": 27
  },
  "胡萝卜": {
    "kcal": 41,
    "protein": 0.9,
    "carbs": 10,
    "fat": 0.2,
    "fiber": 2.8,
    "sugar": 4.5,
    "sodium": 25
  },
  "白萝卜": {
    "kcal": 21,
    "protein": 0.9,
    "carbs": 5,
    "fat": 0.1,
    "fiber": 1.6,
    "sugar": 3,
    "sodium": 40
  },
  "红萝卜": {
    "kcal": 21,
    "protein": 0.9,
    "carbs": 5,
    "fat": 0.1,
    "fiber": 1.6,
    "sugar": 3,
    "sodium": 40
  },
  "青萝卜": {
    "kcal": 31,
    "protein": 1.2,
    "carbs": 6.8,
    "fat": 0.2,
    "fiber": 2,
    "sugar": 3.5,
    "sodium": 40
  },
  "茄子": {
    "kcal": 25,
    "protein": 1,
    "carbs": 6,
    "fat": 0.2,
    "fiber": 1,
    "sugar": 2.5,
    "sodium": 1
  },
  "青椒": {
    "kcal": 22,
    "protein": 1,
    "carbs": 5,
    "fat": 0.2,
    "fiber": 1.7,
    "sugar": 2,
    "sodium": 2
  },
  "红椒": {
    "kcal": 26,
    "protein": 1,
    "carbs": 6,
    "fat": 0.3,
    "fiber": 1.7,
    "sugar": 3.5,
    "sodium": 3
  },
  "彩椒": {
    "kcal": 26,
    "protein": 1,
    "carbs": 6,
    "fat": 0.3,
    "fiber": 1.7,
    "sugar": 3.5,
    "sodium": 3
  },
  "尖椒": {
    "kcal": 23,
    "protein": 1,
    "carbs": 5,
    "fat": 0.2,
    "fiber": 1.5,
    "sugar": 2.5,
    "sodium": 3
  },
  "蘑菇": {
    "kcal": 26,
    "protein": 2.2,
    "carbs": 5,
    "fat": 0.3,
    "fiber": 1,
    "sugar": 2,
    "sodium": 5
  },
  "香菇": {
    "kcal": 26,
    "protein": 2.2,
    "carbs": 5,
    "fat": 0.3,
    "fiber": 3.3,
    "sugar": 1,
    "sodium": 3
  },
  "金针菇": {
    "kcal": 26,
    "protein": 2.4,
    "carbs": 6,
    "fat": 0.4,
    "fiber": 2.7,
    "sugar": 1,
    "sodium": 2
  },
  "杏鲍菇": {
    "kcal": 31,
    "protein": 2.1,
    "carbs": 8.3,
    "fat": 0.1,
    "fiber": 2.1,
    "sugar": 1,
    "sodium": 1
  },
  "平菇": {
    "kcal": 24,
    "protein": 1.9,
    "carbs": 5,
    "fat": 0.3,
    "fiber": 2.3,
    "sugar": 1,
    "sodium": 2
  },
  "口蘑": {
    "kcal": 24,
    "protein": 3.1,
    "carbs": 3.7,
    "fat": 0.3,
    "fiber": 1.2,
    "sugar": 1,
    "sodium": 5
  },
  "木耳": {
    "kcal": 21,
    "protein": 1.5,
    "carbs": 6,
    "fat": 0.2,
    "fiber": 2.6,
    "sugar": 0.2,
    "sodium": 10
  },
  "银耳": {
    "kcal": 36,
    "protein": 1.4,
    "carbs": 8.8,
    "fat": 0.2,
    "fiber": 2.6,
    "sugar": 0.1,
    "sodium": 12
  },
  "洋葱": {
    "kcal": 40,
    "protein": 1.1,
    "carbs": 9,
    "fat": 0.1,
    "fiber": 1.7,
    "sugar": 4.2,
    "sodium": 4
  },
  "冬瓜": {
    "kcal": 12,
    "protein": 0.4,
    "carbs": 2.6,
    "fat": 0.2,
    "fiber": 0.7,
    "sugar": 1.2,
    "sodium": 1
  },
  "西葫芦": {
    "kcal": 18,
    "protein": 0.8,
    "carbs": 3.8,
    "fat": 0.2,
    "fiber": 1,
    "sugar": 1.8,
    "sodium": 2
  },
  "苦瓜": {
    "kcal": 19,
    "protein": 1,
    "carbs": 4,
    "fat": 0.1,
    "fiber": 1.4,
    "sugar": 1.5,
    "sodium": 2
  },
  "丝瓜": {
    "kcal": 20,
    "protein": 1,
    "carbs": 4.2,
    "fat": 0.2,
    "fiber": 0.6,
    "sugar": 1.8,
    "sodium": 2
  },
  "莲藕": {
    "kcal": 73,
    "protein": 1.9,
    "carbs": 17.2,
    "fat": 0.1,
    "fiber": 2.2,
    "sugar": 4,
    "sodium": 4
  },
  "莴笋": {
    "kcal": 15,
    "protein": 1,
    "carbs": 2.8,
    "fat": 0.2,
    "fiber": 0.7,
    "sugar": 1,
    "sodium": 6
  },
  "笋": {
    "kcal": 25,
    "protein": 2.6,
    "carbs": 3.6,
    "fat": 0.3,
    "fiber": 2,
    "sugar": 1.2,
    "sodium": 2
  },
  "竹笋": {
    "kcal": 25,
    "protein": 2.6,
    "carbs": 3.6,
    "fat": 0.3,
    "fiber": 2,
    "sugar": 1.2,
    "sodium": 2
  },
  "芹菜": {
    "kcal": 16,
    "protein": 0.7,
    "carbs": 3.4,
    "fat": 0.2,
    "fiber": 1.6,
    "sugar": 0.6,
    "sodium": 80
  },
  "韭菜": {
    "kcal": 26,
    "protein": 2.4,
    "carbs": 4.6,
    "fat": 0.3,
    "fiber": 1.4,
    "sugar": 1.4,
    "sodium": 6
  },
  "蒜苔": {
    "kcal": 37,
    "protein": 2.2,
    "carbs": 7.5,
    "fat": 0.2,
    "fiber": 2.5,
    "sugar": 1,
    "sodium": 2
  },
  "蒜薹": {
    "kcal": 37,
    "protein": 2.2,
    "carbs": 7.5,
    "fat": 0.2,
    "fiber": 2.5,
    "sugar": 1,
    "sodium": 2
  },
  "蒜叶": {
    "kcal": 37,
    "protein": 2.2,
    "carbs": 7.5,
    "fat": 0.2,
    "fiber": 2.5,
    "sugar": 1,
    "sodium": 2
  },
  "蒜苗": {
    "kcal": 37,
    "protein": 2.2,
    "carbs": 7.5,
    "fat": 0.2,
    "fiber": 2.5,
    "sugar": 1,
    "sodium": 2
  },
  "蒜黄": {
    "kcal": 32,
    "protein": 2,
    "carbs": 6.5,
    "fat": 0.2,
    "fiber": 2,
    "sugar": 1,
    "sodium": 2
  },
  "茼蒿": {
    "kcal": 21,
    "protein": 1.9,
    "carbs": 3.9,
    "fat": 0.3,
    "fiber": 1.6,
    "sugar": 1,
    "sodium": 20
  },
  "豆角": {
    "kcal": 34,
    "protein": 2.5,
    "carbs": 6.7,
    "fat": 0.2,
    "fiber": 2.1,
    "sugar": 1,
    "sodium": 2
  },
  "四季豆": {
    "kcal": 31,
    "protein": 2,
    "carbs": 6.3,
    "fat": 0.2,
    "fiber": 2,
    "sugar": 1,
    "sodium": 2
  },
  "豇豆": {
    "kcal": 33,
    "protein": 2.1,
    "carbs": 6.4,
    "fat": 0.2,
    "fiber": 2.3,
    "sugar": 1.2,
    "sodium": 2
  },
  "荷兰豆": {
    "kcal": 30,
    "protein": 2.5,
    "carbs": 5,
    "fat": 0.2,
    "fiber": 2,
    "sugar": 1.2,
    "sodium": 2
  },
  "毛豆": {
    "kcal": 131,
    "protein": 13.1,
    "carbs": 10.5,
    "fat": 5,
    "fiber": 4.2,
    "sugar": 2.5,
    "sodium": 2
  },
  "豌豆": {
    "kcal": 105,
    "protein": 7.4,
    "carbs": 18.2,
    "fat": 0.4,
    "fiber": 4.5,
    "sugar": 4,
    "sodium": 4
  },
  "蚕豆": {
    "kcal": 111,
    "protein": 8.8,
    "carbs": 19.5,
    "fat": 0.4,
    "fiber": 3.6,
    "sugar": 2.5,
    "sodium": 4
  },
  "秋葵": {
    "kcal": 37,
    "protein": 2,
    "carbs": 7,
    "fat": 0.2,
    "fiber": 3.2,
    "sugar": 1.5,
    "sodium": 8
  },
  "绿豆芽": {
    "kcal": 18,
    "protein": 2.1,
    "carbs": 2.9,
    "fat": 0.1,
    "fiber": 0.8,
    "sugar": 0.4,
    "sodium": 3
  },
  "黄豆芽": {
    "kcal": 47,
    "protein": 4.5,
    "carbs": 4.5,
    "fat": 1.6,
    "fiber": 1.8,
    "sugar": 0.7,
    "sodium": 4
  },
  "豆芽": {
    "kcal": 47,
    "protein": 4.5,
    "carbs": 4.5,
    "fat": 1.6,
    "fiber": 1.8,
    "sugar": 0.7,
    "sodium": 4
  },
  "苹果": {
    "kcal": 52,
    "protein": 0.3,
    "carbs": 14,
    "fat": 0.2,
    "fiber": 2.4,
    "sugar": 10.4,
    "sodium": 1
  },
  "红富士苹果": {
    "kcal": 54,
    "protein": 0.2,
    "carbs": 14,
    "fat": 0.2,
    "fiber": 2,
    "sugar": 10,
    "sodium": 1
  },
  "香蕉": {
    "kcal": 93,
    "protein": 1.4,
    "carbs": 22,
    "fat": 0.2,
    "fiber": 2.6,
    "sugar": 12.2,
    "sodium": 1
  },
  "橙子": {
    "kcal": 47,
    "protein": 0.8,
    "carbs": 12,
    "fat": 0.2,
    "fiber": 2.4,
    "sugar": 9.4,
    "sodium": 0
  },
  "橘子": {
    "kcal": 47,
    "protein": 0.8,
    "carbs": 12,
    "fat": 0.2,
    "fiber": 2.4,
    "sugar": 9.4,
    "sodium": 0
  },
  "柚子": {
    "kcal": 42,
    "protein": 0.8,
    "carbs": 9.5,
    "fat": 0.2,
    "fiber": 0.4,
    "sugar": 7,
    "sodium": 1
  },
  "柠檬": {
    "kcal": 37,
    "protein": 1.1,
    "carbs": 9.3,
    "fat": 0.3,
    "fiber": 2.8,
    "sugar": 2.5,
    "sodium": 1
  },
  "梨": {
    "kcal": 57,
    "protein": 0.4,
    "carbs": 15,
    "fat": 0.1,
    "fiber": 3.1,
    "sugar": 9.8,
    "sodium": 1
  },
  "葡萄": {
    "kcal": 43,
    "protein": 0.5,
    "carbs": 10,
    "fat": 0.2,
    "fiber": 0.9,
    "sugar": 9.2,
    "sodium": 2
  },
  "草莓": {
    "kcal": 32,
    "protein": 0.7,
    "carbs": 7.7,
    "fat": 0.3,
    "fiber": 2,
    "sugar": 4.9,
    "sodium": 1
  },
  "西瓜": {
    "kcal": 30,
    "protein": 0.6,
    "carbs": 7.6,
    "fat": 0.2,
    "fiber": 0.4,
    "sugar": 6.2,
    "sodium": 1
  },
  "猕猴桃": {
    "kcal": 61,
    "protein": 1.1,
    "carbs": 15,
    "fat": 0.5,
    "fiber": 3,
    "sugar": 9,
    "sodium": 3
  },
  "蓝莓": {
    "kcal": 57,
    "protein": 0.7,
    "carbs": 14,
    "fat": 0.3,
    "fiber": 2.4,
    "sugar": 10,
    "sodium": 1
  },
  "桃子": {
    "kcal": 39,
    "protein": 0.9,
    "carbs": 10,
    "fat": 0.3,
    "fiber": 1.5,
    "sugar": 8.4,
    "sodium": 0
  },
  "芒果": {
    "kcal": 60,
    "protein": 0.8,
    "carbs": 15,
    "fat": 0.4,
    "fiber": 1.6,
    "sugar": 14,
    "sodium": 1
  },
  "菠萝": {
    "kcal": 50,
    "protein": 0.5,
    "carbs": 13,
    "fat": 0.1,
    "fiber": 1.4,
    "sugar": 9.9,
    "sodium": 1
  },
  "樱桃": {
    "kcal": 46,
    "protein": 1.1,
    "carbs": 10.2,
    "fat": 0.2,
    "fiber": 2.1,
    "sugar": 8,
    "sodium": 0
  },
  "哈密瓜": {
    "kcal": 34,
    "protein": 0.8,
    "carbs": 8,
    "fat": 0.2,
    "fiber": 0.9,
    "sugar": 7,
    "sodium": 12
  },
  "甜瓜": {
    "kcal": 26,
    "protein": 0.8,
    "carbs": 6.2,
    "fat": 0.2,
    "fiber": 0.9,
    "sugar": 5,
    "sodium": 12
  },
  "木瓜": {
    "kcal": 30,
    "protein": 0.4,
    "carbs": 7.8,
    "fat": 0.2,
    "fiber": 1.7,
    "sugar": 5.5,
    "sodium": 3
  },
  "火龙果": {
    "kcal": 51,
    "protein": 1.1,
    "carbs": 13,
    "fat": 0.4,
    "fiber": 1.6,
    "sugar": 8,
    "sodium": 1
  },
  "荔枝": {
    "kcal": 71,
    "protein": 0.9,
    "carbs": 16.5,
    "fat": 0.2,
    "fiber": 1.3,
    "sugar": 13,
    "sodium": 1
  },
  "龙眼": {
    "kcal": 71,
    "protein": 1.2,
    "carbs": 16.5,
    "fat": 0.1,
    "fiber": 0.4,
    "sugar": 14,
    "sodium": 1
  },
  "桂圆": {
    "kcal": 71,
    "protein": 1.2,
    "carbs": 16.5,
    "fat": 0.1,
    "fiber": 0.4,
    "sugar": 14,
    "sodium": 1
  },
  "石榴": {
    "kcal": 72,
    "protein": 1.4,
    "carbs": 18,
    "fat": 0.2,
    "fiber": 4,
    "sugar": 13,
    "sodium": 1
  },
  "杨梅": {
    "kcal": 30,
    "protein": 0.8,
    "carbs": 7,
    "fat": 0.2,
    "fiber": 1,
    "sugar": 5,
    "sodium": 1
  },
  "李子": {
    "kcal": 36,
    "protein": 0.7,
    "carbs": 8.7,
    "fat": 0.2,
    "fiber": 0.9,
    "sugar": 7,
    "sodium": 1
  },
  "杏": {
    "kcal": 36,
    "protein": 0.9,
    "carbs": 9,
    "fat": 0.1,
    "fiber": 1.3,
    "sugar": 7,
    "sodium": 1
  },
  "枇杷": {
    "kcal": 39,
    "protein": 0.8,
    "carbs": 9.3,
    "fat": 0.2,
    "fiber": 0.8,
    "sugar": 7,
    "sodium": 1
  },
  "柿子": {
    "kcal": 74,
    "protein": 0.4,
    "carbs": 18.5,
    "fat": 0.2,
    "fiber": 1.4,
    "sugar": 12,
    "sodium": 1
  },
  "椰子": {
    "kcal": 241,
    "protein": 4,
    "carbs": 15,
    "fat": 12,
    "fiber": 4,
    "sugar": 6,
    "sodium": 20
  },
  "牛油果": {
    "kcal": 160,
    "protein": 2,
    "carbs": 9,
    "fat": 15,
    "fiber": 7,
    "sugar": 0.7,
    "sodium": 7
  },
  "无花果": {
    "kcal": 74,
    "protein": 0.8,
    "carbs": 19,
    "fat": 0.3,
    "fiber": 2.9,
    "sugar": 16,
    "sodium": 1
  },
  "桑葚": {
    "kcal": 57,
    "protein": 1.7,
    "carbs": 13.8,
    "fat": 0.4,
    "fiber": 4.1,
    "sugar": 8.1,
    "sodium": 2
  },
  "百香果": {
    "kcal": 97,
    "protein": 2.2,
    "carbs": 23,
    "fat": 0.7,
    "fiber": 10.4,
    "sugar": 11,
    "sodium": 28
  },
  "山竹": {
    "kcal": 73,
    "protein": 0.4,
    "carbs": 18,
    "fat": 0.2,
    "fiber": 1.5,
    "sugar": 14,
    "sodium": 1
  },
  "枣": {
    "kcal": 122,
    "protein": 1.1,
    "carbs": 30.5,
    "fat": 0.3,
    "fiber": 6.2,
    "sugar": 25,
    "sodium": 3
  },
  "冬枣": {
    "kcal": 113,
    "protein": 1.1,
    "carbs": 27.5,
    "fat": 0.2,
    "fiber": 3.8,
    "sugar": 22,
    "sodium": 3
  },
  "牛奶": {
    "kcal": 65,
    "protein": 3.3,
    "carbs": 5,
    "fat": 3.6,
    "fiber": 0,
    "sugar": 5,
    "sodium": 43
  },
  "全脂牛奶": {
    "kcal": 65,
    "protein": 3.3,
    "carbs": 5,
    "fat": 3.6,
    "fiber": 0,
    "sugar": 5,
    "sodium": 43
  },
  "脱脂牛奶": {
    "kcal": 35,
    "protein": 3.4,
    "carbs": 5,
    "fat": 0.2,
    "fiber": 0,
    "sugar": 5,
    "sodium": 45
  },
  "低脂牛奶": {
    "kcal": 45,
    "protein": 3.3,
    "carbs": 5,
    "fat": 1.5,
    "fiber": 0,
    "sugar": 5,
    "sodium": 44
  },
  "羊奶": {
    "kcal": 59,
    "protein": 3.5,
    "carbs": 5.4,
    "fat": 3.5,
    "fiber": 0,
    "sugar": 5,
    "sodium": 40
  },
  "酸奶": {
    "kcal": 72,
    "protein": 3.3,
    "carbs": 9,
    "fat": 3,
    "fiber": 0,
    "sugar": 8,
    "sodium": 55
  },
  "希腊酸奶": {
    "kcal": 59,
    "protein": 10,
    "carbs": 3.6,
    "fat": 0.4,
    "fiber": 0,
    "sugar": 3.2,
    "sodium": 36
  },
  "奶酪": {
    "kcal": 328,
    "protein": 25.7,
    "carbs": 3.5,
    "fat": 24,
    "fiber": 0,
    "sugar": 1,
    "sodium": 620
  },
  "芝士": {
    "kcal": 328,
    "protein": 25.7,
    "carbs": 3.5,
    "fat": 24,
    "fiber": 0,
    "sugar": 1,
    "sodium": 620
  },
  "黄油": {
    "kcal": 717,
    "protein": 0.9,
    "carbs": 0.1,
    "fat": 81,
    "fiber": 0,
    "sugar": 0.1,
    "sodium": 11
  },
  "奶油": {
    "kcal": 879,
    "protein": 0.7,
    "carbs": 3.7,
    "fat": 97,
    "fiber": 0,
    "sugar": 3.7,
    "sodium": 11
  },
  "炼乳": {
    "kcal": 322,
    "protein": 8,
    "carbs": 55,
    "fat": 8,
    "fiber": 0,
    "sugar": 50,
    "sodium": 200
  },
  "奶茶": {
    "kcal": 65,
    "protein": 2,
    "carbs": 10.5,
    "fat": 2.5,
    "fiber": 0,
    "sugar": 10,
    "sodium": 40
  },
  "豆浆": {
    "kcal": 31,
    "protein": 3,
    "carbs": 1.2,
    "fat": 1.9,
    "fiber": 0.1,
    "sugar": 0.5,
    "sodium": 12
  },
  "豆腐脑": {
    "kcal": 15,
    "protein": 1.9,
    "carbs": 0,
    "fat": 0.8,
    "fiber": 0,
    "sugar": 0,
    "sodium": 5
  },
  "豆奶": {
    "kcal": 30,
    "protein": 2.4,
    "carbs": 2.6,
    "fat": 1.5,
    "fiber": 0.1,
    "sugar": 1,
    "sodium": 10
  },
  "酸梅汤": {
    "kcal": 40,
    "protein": 0.1,
    "carbs": 10,
    "fat": 0,
    "fiber": 0,
    "sugar": 9,
    "sodium": 5
  },
  "可乐": {
    "kcal": 43,
    "protein": 0,
    "carbs": 10.6,
    "fat": 0,
    "fiber": 0,
    "sugar": 10.6,
    "sodium": 5
  },
  "雪碧": {
    "kcal": 45,
    "protein": 0,
    "carbs": 11,
    "fat": 0,
    "fiber": 0,
    "sugar": 11,
    "sodium": 5
  },
  "橙汁": {
    "kcal": 45,
    "protein": 0.7,
    "carbs": 10,
    "fat": 0.2,
    "fiber": 0.2,
    "sugar": 8.4,
    "sodium": 1
  },
  "苹果汁": {
    "kcal": 46,
    "protein": 0.1,
    "carbs": 11,
    "fat": 0.1,
    "fiber": 0.2,
    "sugar": 10,
    "sodium": 1
  },
  "葡萄汁": {
    "kcal": 63,
    "protein": 0.4,
    "carbs": 15,
    "fat": 0.1,
    "fiber": 0.2,
    "sugar": 14,
    "sodium": 2
  },
  "咖啡": {
    "kcal": 2,
    "protein": 0.1,
    "carbs": 0,
    "fat": 0,
    "fiber": 0,
    "sugar": 0,
    "sodium": 2
  },
  "美式咖啡": {
    "kcal": 2,
    "protein": 0.1,
    "carbs": 0,
    "fat": 0,
    "fiber": 0,
    "sugar": 0,
    "sodium": 2
  },
  "拿铁": {
    "kcal": 50,
    "protein": 3,
    "carbs": 4.5,
    "fat": 2,
    "fiber": 0,
    "sugar": 4.5,
    "sodium": 50
  },
  "卡布奇诺": {
    "kcal": 50,
    "protein": 3,
    "carbs": 4.5,
    "fat": 2,
    "fiber": 0,
    "sugar": 4.5,
    "sodium": 50
  },
  "摩卡": {
    "kcal": 90,
    "protein": 3,
    "carbs": 10,
    "fat": 4,
    "fiber": 0,
    "sugar": 9,
    "sodium": 50
  },
  "啤酒": {
    "kcal": 43,
    "protein": 0.5,
    "carbs": 3.6,
    "fat": 0,
    "fiber": 0,
    "sugar": 0,
    "sodium": 4
  },
  "红酒": {
    "kcal": 85,
    "protein": 0.1,
    "carbs": 2.6,
    "fat": 0,
    "fiber": 0,
    "sugar": 1,
    "sodium": 5
  },
  "白酒": {
    "kcal": 298,
    "protein": 0.1,
    "carbs": 0,
    "fat": 0,
    "fiber": 0,
    "sugar": 0,
    "sodium": 1
  },
  "黄酒": {
    "kcal": 66,
    "protein": 1.6,
    "carbs": 5,
    "fat": 0,
    "fiber": 0,
    "sugar": 0,
    "sodium": 5
  },
  "黄豆": {
    "kcal": 390,
    "protein": 35,
    "carbs": 34,
    "fat": 16,
    "fiber": 15.5,
    "sugar": 7,
    "sodium": 2
  },
  "黑豆": {
    "kcal": 381,
    "protein": 36,
    "carbs": 33,
    "fat": 15,
    "fiber": 10.2,
    "sugar": 7,
    "sodium": 3
  },
  "绿豆": {
    "kcal": 347,
    "protein": 23,
    "carbs": 62,
    "fat": 0.8,
    "fiber": 6.4,
    "sugar": 4,
    "sodium": 3
  },
  "红豆": {
    "kcal": 324,
    "protein": 20,
    "carbs": 63,
    "fat": 0.6,
    "fiber": 7.7,
    "sugar": 4,
    "sodium": 2
  },
  "扁豆": {
    "kcal": 339,
    "protein": 25,
    "carbs": 61,
    "fat": 0.4,
    "fiber": 6.5,
    "sugar": 4,
    "sodium": 2
  },
  "豆腐": {
    "kcal": 84,
    "protein": 8.1,
    "carbs": 3.8,
    "fat": 4.8,
    "fiber": 0.4,
    "sugar": 0.6,
    "sodium": 7
  },
  "北豆腐": {
    "kcal": 98,
    "protein": 12.2,
    "carbs": 2,
    "fat": 4.6,
    "fiber": 0.4,
    "sugar": 0.6,
    "sodium": 7
  },
  "南豆腐": {
    "kcal": 87,
    "protein": 6.2,
    "carbs": 3.8,
    "fat": 4.8,
    "fiber": 0.4,
    "sugar": 0.6,
    "sodium": 7
  },
  "内酯豆腐": {
    "kcal": 50,
    "protein": 5,
    "carbs": 2.5,
    "fat": 2,
    "fiber": 0.4,
    "sugar": 0.6,
    "sodium": 7
  },
  "豆腐干": {
    "kcal": 140,
    "protein": 16.2,
    "carbs": 6,
    "fat": 6.7,
    "fiber": 0.4,
    "sugar": 0.5,
    "sodium": 300
  },
  "香干": {
    "kcal": 153,
    "protein": 15.8,
    "carbs": 5,
    "fat": 7.8,
    "fiber": 0.4,
    "sugar": 0.5,
    "sodium": 330
  },
  "千张": {
    "kcal": 262,
    "protein": 24.5,
    "carbs": 5,
    "fat": 16,
    "fiber": 0.5,
    "sugar": 0.5,
    "sodium": 30
  },
  "腐竹": {
    "kcal": 459,
    "protein": 44.6,
    "carbs": 21.3,
    "fat": 21.7,
    "fiber": 1,
    "sugar": 0.5,
    "sodium": 26
  },
  "豆皮": {
    "kcal": 410,
    "protein": 44,
    "carbs": 18,
    "fat": 18,
    "fiber": 1,
    "sugar": 0.5,
    "sodium": 20
  },
  "油豆腐": {
    "kcal": 244,
    "protein": 17,
    "carbs": 5,
    "fat": 17,
    "fiber": 0.4,
    "sugar": 0.5,
    "sodium": 150
  },
  "素鸡": {
    "kcal": 194,
    "protein": 16,
    "carbs": 6,
    "fat": 12,
    "fiber": 0.4,
    "sugar": 0.5,
    "sodium": 350
  },
  "臭豆腐": {
    "kcal": 150,
    "protein": 12,
    "carbs": 4,
    "fat": 10,
    "fiber": 0.4,
    "sugar": 0.5,
    "sodium": 300
  },
  "花生": {
    "kcal": 567,
    "protein": 26,
    "carbs": 16,
    "fat": 49,
    "fiber": 8.5,
    "sugar": 4.7,
    "sodium": 18
  },
  "花生米": {
    "kcal": 581,
    "protein": 26,
    "carbs": 16,
    "fat": 49,
    "fiber": 8.5,
    "sugar": 4.7,
    "sodium": 18
  },
  "瓜子": {
    "kcal": 597,
    "protein": 30,
    "carbs": 10,
    "fat": 50,
    "fiber": 6,
    "sugar": 2.5,
    "sodium": 50
  },
  "葵花籽": {
    "kcal": 597,
    "protein": 30,
    "carbs": 10,
    "fat": 50,
    "fiber": 6,
    "sugar": 2.5,
    "sodium": 50
  },
  "核桃": {
    "kcal": 654,
    "protein": 15,
    "carbs": 14,
    "fat": 65,
    "fiber": 6.7,
    "sugar": 2.6,
    "sodium": 2
  },
  "腰果": {
    "kcal": 553,
    "protein": 18,
    "carbs": 30,
    "fat": 44,
    "fiber": 3.3,
    "sugar": 5.9,
    "sodium": 12
  },
  "杏仁": {
    "kcal": 579,
    "protein": 21,
    "carbs": 22,
    "fat": 50,
    "fiber": 12.5,
    "sugar": 4.4,
    "sodium": 1
  },
  "开心果": {
    "kcal": 562,
    "protein": 20,
    "carbs": 28,
    "fat": 45,
    "fiber": 10.6,
    "sugar": 7.7,
    "sodium": 1
  },
  "榛子": {
    "kcal": 617,
    "protein": 12,
    "carbs": 17,
    "fat": 60,
    "fiber": 9.6,
    "sugar": 4,
    "sodium": 3
  },
  "夏威夷果": {
    "kcal": 718,
    "protein": 8,
    "carbs": 14,
    "fat": 76,
    "fiber": 8.6,
    "sugar": 4.6,
    "sodium": 5
  },
  "碧根果": {
    "kcal": 691,
    "protein": 9,
    "carbs": 14,
    "fat": 72,
    "fiber": 9.6,
    "sugar": 4,
    "sodium": 3
  },
  "松子": {
    "kcal": 698,
    "protein": 13,
    "carbs": 13,
    "fat": 71,
    "fiber": 10,
    "sugar": 4,
    "sodium": 3
  },
  "板栗": {
    "kcal": 185,
    "protein": 4.2,
    "carbs": 40,
    "fat": 1,
    "fiber": 6,
    "sugar": 8,
    "sodium": 4
  },
  "巴旦木": {
    "kcal": 579,
    "protein": 21,
    "carbs": 22,
    "fat": 50,
    "fiber": 12.5,
    "sugar": 4.4,
    "sodium": 1
  },
  "葡萄干": {
    "kcal": 299,
    "protein": 3.2,
    "carbs": 79,
    "fat": 0.5,
    "fiber": 3.7,
    "sugar": 65,
    "sodium": 28
  },
  "红枣": {
    "kcal": 264,
    "protein": 3.2,
    "carbs": 67.8,
    "fat": 0.5,
    "fiber": 6.2,
    "sugar": 55,
    "sodium": 3
  },
  "桂圆干": {
    "kcal": 273,
    "protein": 5,
    "carbs": 65,
    "fat": 0.5,
    "fiber": 4,
    "sugar": 58,
    "sodium": 20
  },
  "黑芝麻": {
    "kcal": 559,
    "protein": 18,
    "carbs": 24,
    "fat": 46,
    "fiber": 14,
    "sugar": 2,
    "sodium": 11
  },
  "白芝麻": {
    "kcal": 564,
    "protein": 17,
    "carbs": 26,
    "fat": 48,
    "fiber": 12,
    "sugar": 2,
    "sodium": 11
  },
  "巧克力": {
    "kcal": 589,
    "protein": 7.6,
    "carbs": 51,
    "fat": 40,
    "fiber": 7,
    "sugar": 47,
    "sodium": 24
  },
  "黑巧克力": {
    "kcal": 598,
    "protein": 7.8,
    "carbs": 46,
    "fat": 43,
    "fiber": 11,
    "sugar": 24,
    "sodium": 20
  },
  "牛奶巧克力": {
    "kcal": 535,
    "protein": 8,
    "carbs": 59,
    "fat": 30,
    "fiber": 3.4,
    "sugar": 52,
    "sodium": 80
  },
  "饼干": {
    "kcal": 433,
    "protein": 6,
    "carbs": 65,
    "fat": 17,
    "fiber": 1.5,
    "sugar": 30,
    "sodium": 400
  },
  "苏打饼干": {
    "kcal": 408,
    "protein": 9,
    "carbs": 68,
    "fat": 12,
    "fiber": 2,
    "sugar": 3,
    "sodium": 500
  },
  "威化饼干": {
    "kcal": 472,
    "protein": 5,
    "carbs": 70,
    "fat": 20,
    "fiber": 1,
    "sugar": 40,
    "sodium": 300
  },
  "夹心饼干": {
    "kcal": 450,
    "protein": 6,
    "carbs": 68,
    "fat": 18,
    "fiber": 1,
    "sugar": 35,
    "sodium": 350
  },
  "蛋糕": {
    "kcal": 348,
    "protein": 5,
    "carbs": 53,
    "fat": 13,
    "fiber": 0.6,
    "sugar": 36,
    "sodium": 200
  },
  "芝士蛋糕": {
    "kcal": 321,
    "protein": 7,
    "carbs": 30,
    "fat": 19,
    "fiber": 0.6,
    "sugar": 22,
    "sodium": 250
  },
  "提拉米苏": {
    "kcal": 310,
    "protein": 6,
    "carbs": 32,
    "fat": 18,
    "fiber": 0.5,
    "sugar": 22,
    "sodium": 200
  },
  "甜甜圈": {
    "kcal": 452,
    "protein": 5,
    "carbs": 51,
    "fat": 25,
    "fiber": 1.4,
    "sugar": 20,
    "sodium": 300
  },
  "马卡龙": {
    "kcal": 370,
    "protein": 5,
    "carbs": 65,
    "fat": 13,
    "fiber": 1,
    "sugar": 50,
    "sodium": 100
  },
  "薯片": {
    "kcal": 548,
    "protein": 7,
    "carbs": 53,
    "fat": 35,
    "fiber": 4.4,
    "sugar": 0.5,
    "sodium": 536
  },
  "薯条": {
    "kcal": 298,
    "protein": 3.4,
    "carbs": 41,
    "fat": 14,
    "fiber": 3,
    "sugar": 0.3,
    "sodium": 210
  },
  "爆米花": {
    "kcal": 375,
    "protein": 11,
    "carbs": 73,
    "fat": 5,
    "fiber": 13,
    "sugar": 1,
    "sodium": 500
  },
  "冰淇淋": {
    "kcal": 127,
    "protein": 2.4,
    "carbs": 21,
    "fat": 4,
    "fiber": 0,
    "sugar": 18,
    "sodium": 50
  },
  "雪糕": {
    "kcal": 180,
    "protein": 2.5,
    "carbs": 24,
    "fat": 8,
    "fiber": 0,
    "sugar": 20,
    "sodium": 70
  },
  "糖果": {
    "kcal": 396,
    "protein": 0,
    "carbs": 99,
    "fat": 0,
    "fiber": 0,
    "sugar": 90,
    "sodium": 20
  },
  "红烧肉": {
    "kcal": 480,
    "protein": 9,
    "carbs": 12,
    "fat": 45,
    "fiber": 0,
    "sugar": 3,
    "sodium": 800
  },
  "回锅肉": {
    "kcal": 450,
    "protein": 10,
    "carbs": 5,
    "fat": 42,
    "fiber": 0.5,
    "sugar": 2,
    "sodium": 700
  },
  "宫保鸡丁": {
    "kcal": 200,
    "protein": 14,
    "carbs": 12,
    "fat": 11,
    "fiber": 1.5,
    "sugar": 4,
    "sodium": 700
  },
  "鱼香肉丝": {
    "kcal": 150,
    "protein": 10,
    "carbs": 9,
    "fat": 8,
    "fiber": 1,
    "sugar": 5,
    "sodium": 680
  },
  "麻婆豆腐": {
    "kcal": 120,
    "protein": 8,
    "carbs": 8,
    "fat": 7,
    "fiber": 0.8,
    "sugar": 1.5,
    "sodium": 600
  },
  "西红柿炒蛋": {
    "kcal": 95,
    "protein": 6,
    "carbs": 6,
    "fat": 6,
    "fiber": 0.6,
    "sugar": 3.5,
    "sodium": 320
  },
  "番茄炒蛋": {
    "kcal": 95,
    "protein": 6,
    "carbs": 6,
    "fat": 6,
    "fiber": 0.6,
    "sugar": 3.5,
    "sodium": 320
  },
  "青椒肉丝": {
    "kcal": 130,
    "protein": 10,
    "carbs": 6,
    "fat": 8,
    "fiber": 1,
    "sugar": 3,
    "sodium": 500
  },
  "糖醋里脊": {
    "kcal": 300,
    "protein": 12,
    "carbs": 25,
    "fat": 15,
    "fiber": 0.5,
    "sugar": 12,
    "sodium": 600
  },
  "可乐鸡翅": {
    "kcal": 220,
    "protein": 12,
    "carbs": 12,
    "fat": 12,
    "fiber": 0,
    "sugar": 8,
    "sodium": 500
  },
  "红烧排骨": {
    "kcal": 320,
    "protein": 14,
    "carbs": 10,
    "fat": 22,
    "fiber": 0,
    "sugar": 5,
    "sodium": 700
  },
  "清蒸鱼": {
    "kcal": 120,
    "protein": 18,
    "carbs": 2,
    "fat": 5,
    "fiber": 0,
    "sugar": 1,
    "sodium": 400
  },
  "水煮鱼": {
    "kcal": 180,
    "protein": 16,
    "carbs": 5,
    "fat": 10,
    "fiber": 0.5,
    "sugar": 1,
    "sodium": 900
  },
  "酸菜鱼": {
    "kcal": 160,
    "protein": 16,
    "carbs": 6,
    "fat": 8,
    "fiber": 0.5,
    "sugar": 1,
    "sodium": 900
  },
  "辣子鸡": {
    "kcal": 280,
    "protein": 16,
    "carbs": 10,
    "fat": 18,
    "fiber": 1,
    "sugar": 2,
    "sodium": 800
  },
  "烤鸭": {
    "kcal": 300,
    "protein": 16,
    "carbs": 6,
    "fat": 24,
    "fiber": 0,
    "sugar": 1,
    "sodium": 700
  },
  "白切鸡": {
    "kcal": 190,
    "protein": 20,
    "carbs": 1,
    "fat": 12,
    "fiber": 0,
    "sugar": 0,
    "sodium": 200
  },
  "油焖大虾": {
    "kcal": 180,
    "protein": 16,
    "carbs": 8,
    "fat": 8,
    "fiber": 0,
    "sugar": 4,
    "sodium": 800
  },
  "地三鲜": {
    "kcal": 130,
    "protein": 2,
    "carbs": 18,
    "fat": 6,
    "fiber": 2,
    "sugar": 3,
    "sodium": 400
  },
  "干煸豆角": {
    "kcal": 180,
    "protein": 4,
    "carbs": 16,
    "fat": 11,
    "fiber": 3,
    "sugar": 4,
    "sodium": 600
  },
  "蒜蓉西兰花": {
    "kcal": 80,
    "protein": 3,
    "carbs": 9,
    "fat": 4,
    "fiber": 2.5,
    "sugar": 2,
    "sodium": 300
  },
  "炒饭": {
    "kcal": 180,
    "protein": 5,
    "carbs": 30,
    "fat": 5,
    "fiber": 0.8,
    "sugar": 1,
    "sodium": 500
  },
  "蛋炒饭": {
    "kcal": 180,
    "protein": 5,
    "carbs": 30,
    "fat": 5,
    "fiber": 0.8,
    "sugar": 1,
    "sodium": 500
  },
  "扬州炒饭": {
    "kcal": 190,
    "protein": 6,
    "carbs": 30,
    "fat": 6,
    "fiber": 0.8,
    "sugar": 1,
    "sodium": 520
  },
  "盖浇饭": {
    "kcal": 170,
    "protein": 6,
    "carbs": 28,
    "fat": 4,
    "fiber": 0.7,
    "sugar": 1.5,
    "sodium": 550
  },
  "牛肉面": {
    "kcal": 120,
    "protein": 7,
    "carbs": 16,
    "fat": 3,
    "fiber": 0.8,
    "sugar": 1,
    "sodium": 850
  },
  "拉面": {
    "kcal": 110,
    "protein": 5,
    "carbs": 20,
    "fat": 2,
    "fiber": 0.6,
    "sugar": 0.8,
    "sodium": 900
  },
  "炸酱面": {
    "kcal": 160,
    "protein": 6,
    "carbs": 25,
    "fat": 4,
    "fiber": 0.8,
    "sugar": 2,
    "sodium": 800
  },
  "凉面": {
    "kcal": 150,
    "protein": 5,
    "carbs": 28,
    "fat": 3,
    "fiber": 0.8,
    "sugar": 1,
    "sodium": 600
  },
  "热干面": {
    "kcal": 170,
    "protein": 6,
    "carbs": 28,
    "fat": 5,
    "fiber": 0.8,
    "sugar": 1,
    "sodium": 700
  },
  "担担面": {
    "kcal": 180,
    "protein": 7,
    "carbs": 24,
    "fat": 7,
    "fiber": 0.8,
    "sugar": 1.5,
    "sodium": 800
  },
  "披萨": {
    "kcal": 266,
    "protein": 11,
    "carbs": 33,
    "fat": 10,
    "fiber": 2.3,
    "sugar": 3.6,
    "sodium": 598
  },
  "汉堡": {
    "kcal": 295,
    "protein": 14,
    "carbs": 25,
    "fat": 14,
    "fiber": 1.6,
    "sugar": 6,
    "sodium": 540
  },
  "炸鸡": {
    "kcal": 320,
    "protein": 18,
    "carbs": 15,
    "fat": 20,
    "fiber": 0.8,
    "sugar": 0.5,
    "sodium": 600
  },
  "鸡米花": {
    "kcal": 300,
    "protein": 16,
    "carbs": 18,
    "fat": 16,
    "fiber": 0.8,
    "sugar": 0.5,
    "sodium": 600
  },
  "寿司": {
    "kcal": 150,
    "protein": 5,
    "carbs": 28,
    "fat": 2,
    "fiber": 0.5,
    "sugar": 2,
    "sodium": 320
  },
  "咖喱": {
    "kcal": 130,
    "protein": 4,
    "carbs": 14,
    "fat": 6,
    "fiber": 2,
    "sugar": 0,
    "sodium": 700
  },
  "咖喱饭": {
    "kcal": 180,
    "protein": 6,
    "carbs": 30,
    "fat": 5,
    "fiber": 1.5,
    "sugar": 3,
    "sodium": 650
  },
  "沙拉": {
    "kcal": 50,
    "protein": 2,
    "carbs": 8,
    "fat": 1,
    "fiber": 1.5,
    "sugar": 2,
    "sodium": 80
  },
  "鸡肉沙拉": {
    "kcal": 130,
    "protein": 12,
    "carbs": 6,
    "fat": 6,
    "fiber": 1.5,
    "sugar": 2,
    "sodium": 200
  },
  "麻辣烫": {
    "kcal": 90,
    "protein": 5,
    "carbs": 8,
    "fat": 4,
    "fiber": 1,
    "sugar": 2,
    "sodium": 1200
  },
  "火锅": {
    "kcal": 110,
    "protein": 9,
    "carbs": 4,
    "fat": 7,
    "fiber": 1,
    "sugar": 2,
    "sodium": 800
  },
  "麻辣香锅": {
    "kcal": 200,
    "protein": 10,
    "carbs": 10,
    "fat": 13,
    "fiber": 1.5,
    "sugar": 3,
    "sodium": 1100
  },
  "煲仔饭": {
    "kcal": 200,
    "protein": 6,
    "carbs": 30,
    "fat": 6,
    "fiber": 0.8,
    "sugar": 1,
    "sodium": 700
  },
  "黄焖鸡米饭": {
    "kcal": 200,
    "protein": 12,
    "carbs": 22,
    "fat": 7,
    "fiber": 0.8,
    "sugar": 1.5,
    "sodium": 750
  },
  "螺蛳粉": {
    "kcal": 170,
    "protein": 4,
    "carbs": 30,
    "fat": 4,
    "fiber": 1,
    "sugar": 1,
    "sodium": 1100
  },
  "过桥米线": {
    "kcal": 130,
    "protein": 4,
    "carbs": 25,
    "fat": 2,
    "fiber": 0.8,
    "sugar": 1,
    "sodium": 900
  },
  "酸辣粉": {
    "kcal": 150,
    "protein": 1.5,
    "carbs": 30,
    "fat": 2,
    "fiber": 1,
    "sugar": 1,
    "sodium": 1000
  },
  "肉夹馍": {
    "kcal": 250,
    "protein": 12,
    "carbs": 30,
    "fat": 9,
    "fiber": 1,
    "sugar": 2,
    "sodium": 600
  },
  "煎饼果子": {
    "kcal": 250,
    "protein": 9,
    "carbs": 35,
    "fat": 8,
    "fiber": 1.5,
    "sugar": 3,
    "sodium": 600
  },
  "鸡蛋灌饼": {
    "kcal": 280,
    "protein": 10,
    "carbs": 34,
    "fat": 11,
    "fiber": 1.5,
    "sugar": 3,
    "sodium": 650
  },
  "驴肉火烧": {
    "kcal": 280,
    "protein": 12,
    "carbs": 32,
    "fat": 11,
    "fiber": 1,
    "sugar": 2,
    "sodium": 600
  },
  "小笼包": {
    "kcal": 220,
    "protein": 8,
    "carbs": 28,
    "fat": 8,
    "fiber": 1,
    "sugar": 2,
    "sodium": 350
  },
  "生煎包": {
    "kcal": 240,
    "protein": 9,
    "carbs": 28,
    "fat": 10,
    "fiber": 1,
    "sugar": 2,
    "sodium": 400
  },
  "叉烧包": {
    "kcal": 250,
    "protein": 8,
    "carbs": 42,
    "fat": 6,
    "fiber": 1,
    "sugar": 12,
    "sodium": 300
  },
  "月饼": {
    "kcal": 420,
    "protein": 7,
    "carbs": 60,
    "fat": 18,
    "fiber": 1.5,
    "sugar": 30,
    "sodium": 80
  },
  "粽子": {
    "kcal": 200,
    "protein": 4,
    "carbs": 40,
    "fat": 2,
    "fiber": 1,
    "sugar": 5,
    "sodium": 50
  },
  "汤圆": {
    "kcal": 250,
    "protein": 4,
    "carbs": 40,
    "fat": 8,
    "fiber": 1,
    "sugar": 12,
    "sodium": 30
  },
  "锅包肉": {
    "kcal": 320,
    "protein": 12,
    "carbs": 28,
    "fat": 16,
    "fiber": 0.5,
    "sugar": 12,
    "sodium": 600
  },
  "糖醋鱼": {
    "kcal": 200,
    "protein": 15,
    "carbs": 12,
    "fat": 10,
    "fiber": 0.5,
    "sugar": 8,
    "sodium": 600
  },
  "卤肉饭": {
    "kcal": 220,
    "protein": 8,
    "carbs": 28,
    "fat": 9,
    "fiber": 0.8,
    "sugar": 2,
    "sodium": 700
  },
  "三明治": {
    "kcal": 230,
    "protein": 12,
    "carbs": 25,
    "fat": 9,
    "fiber": 1.5,
    "sugar": 3,
    "sodium": 500
  },
  "饭团": {
    "kcal": 180,
    "protein": 4,
    "carbs": 35,
    "fat": 3,
    "fiber": 1,
    "sugar": 1,
    "sodium": 300
  },
  "便当": {
    "kcal": 200,
    "protein": 8,
    "carbs": 28,
    "fat": 7,
    "fiber": 1,
    "sugar": 2,
    "sodium": 600
  }
};

const FOOD_ALIASES = {
  "凤梨": "菠萝",
  "奇异果": "猕猴桃",
  "圣女果": "番茄",
  "小番茄": "番茄",
  "圣女番茄": "番茄",
  "提子": "葡萄",
  "车厘子": "樱桃",
  "雪梨": "梨",
  "沙糖桔": "橙子",
  "砂糖橘": "橙子",
  "桔子": "橙子",
  "橘子": "橙子",
  "红提": "葡萄",
  "青提": "葡萄",
  "方便面": "面条",
  "泡面": "面条",
  "白饭": "米饭",
  "米线": "面条",
  "河粉": "面条",
  "牛肉汤面": "牛肉面",
  "牛肉粉": "牛肉面",
  "牛腩面": "牛肉面",
  "清汤牛肉面": "牛肉面",
  "意面": "意大利面",
  "意大利面": "意大利面",
  "年糕": "年糕",
  "拌面": "煮面条",
  "凉面": "凉面",
  "汤面": "煮面条",
  "炸酱面": "炸酱面",
  "热干面": "热干面",
  "重庆小面": "煮面条",
  "阳春面": "煮面条",
  "炒面": "煮面条",
  "油泼面": "煮面条",
  "担担面": "担担面",
  "卡布奇诺": "拿铁",
  "摩卡": "摩卡",
  "美式": "咖啡",
  "馥芮白": "拿铁",
  "生椰拿铁": "拿铁",
  "珍珠奶茶": "奶茶",
  "波霸奶茶": "奶茶",
  "芋圆奶茶": "奶茶",
  "椰果奶茶": "奶茶",
  "土鸡蛋": "鸡蛋",
  "笨鸡蛋": "鸡蛋",
  "里脊": "瘦肉",
  "里脊肉": "瘦肉",
  "牛排": "牛肉",
  "猪排": "排骨",
  "鸡排": "鸡肉",
  "大酱": "黄豆",
  "豆花": "豆腐脑",
  "圆白菜": "卷心菜",
  "洋白菜": "卷心菜",
  "青椒": "青椒",
  "西蓝花": "西兰花",
  "番薯": "红薯",
  "地瓜": "红薯",
  "淮山": "山药",
  "潺菜": "空心菜",
  "大虾": "虾",
  "海虾": "虾",
  "青虾": "虾",
  "花蛤": "蛤蜊",
  "蚬子": "蛤蜊",
  "海蛎子": "牡蛎",
  "生蚝": "生蚝",
  "墨斗鱼": "墨鱼",
  "八爪鱼": "鱿鱼",
  "肯德基": "炸鸡",
  "麦当劳": "汉堡"
};

const SEASONING_PREFIXES = ["可乐","糖醋","红烧","麻辣","香辣","蒜蓉","清蒸","水煮","干煸","回锅","孜然","黑椒","蜜汁","椒盐","剁椒"];

function norm(s) { return (s || '').toLowerCase().replace(/\s+/g, '').replace(/[（(].*?[)）]/g, ''); }

// 镜像 Swift canonicalFoodName + match：去前缀→别名→精确→子串。
function lookupFood(raw) {
  if (!raw) return null;
  let s = String(raw).trim();
  for (const p of SEASONING_PREFIXES) {
    if (s.startsWith(p)) { s = s.slice(p.length); break; }
  }
  if (FOOD_ALIASES[s]) s = FOOD_ALIASES[s];
  if (!s) return null;
  const key = norm(s);
  if (FOOD_TABLE[s]) return { name: s, ...FOOD_TABLE[s] };
  for (const [name, val] of Object.entries(FOOD_TABLE)) {
    if (norm(name) === norm(s)) return { name, ...val };
  }
  for (const [name, val] of Object.entries(FOOD_TABLE)) {
    const nk = norm(name);
    if (nk.includes(key) || key.includes(nk)) return { name, ...val };
  }
  for (const [alias, canon] of Object.entries(FOOD_ALIASES)) {
    if (norm(alias) === key && FOOD_TABLE[canon]) return { name: canon, ...FOOD_TABLE[canon] };
  }
  return null;
}

module.exports = { FOOD_TABLE, FOOD_ALIASES, SEASONING_PREFIXES, lookupFood, SEED_VERSION };
