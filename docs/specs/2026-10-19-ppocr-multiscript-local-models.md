# 本地 OCR：多文字 PaddleOCR 模型与截屏「本地」引擎

## 目标

本地 OCR 原先只有漫画微调的逐列 CTC（Kellenok/PP-OCRv6_manga），只认日文。截屏 /
拍照识字只有系统 OCR 与 Google Lens 两种引擎：系统 OCR 读不了俄文、希腊文等没有
识别器的文字，Lens 要联网并把截图发给 Google。

本次加上 PaddlePaddle 官方的通用识别权重，覆盖更多文字，同一份下载供三处使用：

- 漫画 OCR：设置 › 模型 › OCR 的本地模型下拉；
- 视频图形字幕 OCR：沿用漫画 OCR 的引擎偏好与本地模型；
- 截屏 / 拍照识字：「截屏识字引擎」下拉。

三处的选择方式相同：一个引擎下拉，本地模型逐个列成引擎项，形如「本机 · PaddleOCR v5（韩文）」。旧引擎都保留：系统 OCR、Google Lens、外部 mokuro、配对主机，漫画 CTC 也还是默认本地模型。漫画阅读器的 OCR 设置面板、视频「整轨转文字」确认框里的「OCR 设置」，进的都是同一个下拉。截屏识字的偏好仍存为两个键：`floating_ball.screen_ocr_engine = local` 加 `floating_ball.screen_ocr_local_model`，下拉值 `local:<key>` 只在设置页内部使用。

## 模型

都是 ONNX，在 ONNX Runtime 上直接跑，**不做格式转换**。Android 也经
`flutter_onnxruntime` 跑，不需要 NCNN 之类的原生库。

| key | 识别权重（HF 仓 @ revision） | 文字 | 竖排 |
|---|---|---|---|
| `manga_ctc`（默认） | Kellenok/PP-OCRv6_manga rec v0.2 | 日文（漫画） | 是 |
| `ppocr_v6_small` | PaddlePaddle/PP-OCRv6_small_rec_onnx @ b8f84f0 | 中日文 + 带变音符的拉丁文（含罗马尼亚语 ș ț） | 是 |
| `ppocr_v6_tiny` | PaddlePaddle/PP-OCRv6_tiny_rec_onnx @ 2612ab3 | 拉丁字母语言 | 否 |
| `ppocr_v5_korean` | PaddlePaddle/korean_PP-OCRv5_mobile_rec_onnx @ 5c6f574 | 韩文 | 否 |
| `ppocr_v5_cyrillic` | PaddlePaddle/cyrillic_PP-OCRv5_mobile_rec_onnx @ 2cef881 | 西里尔字母 | 否 |
| `ppocr_v5_greek` | PaddlePaddle/el_PP-OCRv5_mobile_rec_onnx @ 8152b89 | 希腊文 | 否 |
| `ppocr_v5_arabic` | PaddlePaddle/arabic_PP-OCRv5_mobile_rec_onnx @ 14aaedc | 阿拉伯文（从右往左） | 否 |

- 每个模型的清单都是：漫画文字块检测器 + PP-OCRv6 small 行检测器 + 识别权重 +
  同仓的 `inference.yml`（CTC 字典）。
- 每个模型下载到 `<support>/ocr_models/` 下自己的目录，删一个不影响别的。代价是
  两个检测器（约 21 MB）在每个目录里各存一份。
- 语言 → 模型的映射是 `localMangaOcrModelForLanguage`，对齐 Lookupper 的语言表。

### 行检测器（small / tiny）

通用 PaddleOCR 权重在每个文字块里切行 / 切列时，可以选用 PP-OCRv6 small det（默认，
约 9.9 MB，更准）或 PP-OCRv6 tiny det（PaddlePaddle/PP-OCRv6_tiny_det_onnx @ 2ba1506，
约 1.7 MB，更快）。这是一个全局选择，偏好键 `manga_ocr_line_detector`：

- 漫画、视频字幕与截屏识字共用。漫画 OCR 设置（含阅读器面板）与截屏识字设置里都有
  「行检测器」行，只在当前用的是通用 PaddleOCR 模型时出现。
- 漫画 CTC 权重不受影响，恒用 small：它的列检测与去注音阈值是在 small 上调的。
- 两个检测器都在通用模型的清单里，切换不需要再下载；tiny 只多 1.7 MB。
- 偏好在根 isolate 里同步到引擎全局 `mangaOcrLineDetectorChoice`（`loadFromDb` 时和
  设置时各同步一次）。送进 OCR isolate 的是解析好的 `ppDetPath`，外加
  `MangaOcrModelPaths.lineDetectorKey`。
- 逐页缓存签名：选 tiny 时带 `-ppocr_v6_tiny_det` 后缀，与 small 的结果分开存；small
  的签名与加入这个选择之前一样，已有缓存照常命中。

### 完整性

新加的五套权重没能核实精确字节数（开发环境访问不了 HF API），所以
`expectedBytes = 0`，改为钉 LFS sha256：`manga_ocr_model_downloader.dart` 在最后那条
done 事件之前逐个校验，不符的文件删掉并报错。设置页显示的大小用 `estimatedBytes`，
按同一权重 FP16 转换产物的 2.003 倍估算；PP-OCRv6 small 两个已知文件的实测比例就是这个值。

### 字典

CTC 识别器输出的是类别下标，必须用与权重配套的字符表才能还原成文字：下标 0 是
blank，接着是字典里的字符，最后一类是空格。每套权重的字典各不相同，tiny 6904 项、
韩文 11945 项。字典就是同仓 `inference.yml` 里的 `PostProcess.character_dict`。有的
实现会单独导出一份 `dict.txt` 或 `dict.json`，Fushi 下载 `inference.yml` 后用
`parsePpOcrCharacterDict` 直接读，不需要另外的字典文件。

`inference.yml` 没有钉哈希，只做非空检查。不过字典装错时识别不会悄悄出乱码：
`PpOcrLineRecognizer` 会比对模型输出的类别数与「字典项数 + 2」，对不上就报错。

## 文字特征（`OcrScriptTraits`）

漫画流水线里有几条规则原先是按日文写死的，现在按模型取：

- `verticalText`：为 false 时一律按横行读，细高的气泡里是折行的横排短行。
- `dropRuby`：只有日文需要去振假名。
- `spaceBetweenLines`：行与行之间按接缝处的文字补空格。空格挂在前一行行尾，
  `lines.join() == text` 依然成立，逐字区间顺延一位。汉字、假名、全角符号这类不写
  空格的文字不补；前一行以连字符结尾也不补。
- `rightToLeft`：阿拉伯文先把 CTC 的视觉顺序翻回逻辑顺序（与 PaddleOCR 的
  `pred_reverse` 同一规则），这时不出逐字框，点词按行内均分。

另外，页面补检（`page_text_sweep.dart`）只给 `manga_ctc` 建：它只保留日文过半的块，
而且装饰字只有漫画权重读得可靠。

`manga_ctc` 取 `OcrScriptTraits.japanese`，与之前的行为逐项相同。

## 截屏「本地」引擎

实现在 `packages/fushi_engine/lib/ocr/ppocr_screen_reader.dart`，宿主装配在
`fushi/lib/src/floating_ball/screen_ocr_local.dart`。

1. 整屏缩到长边 1280 后跑行检测，行框换回原图坐标。
2. 同方向、粗细比不超过 1.6、上下间距不超过 0.8 倍行厚（或同一排、空隙不超过 1.5
   倍行厚）的行归为一段。
3. 逐行 CTC 识别，竖列逆时针转 90°。吐字帧最小置信度低于 0.3 的行丢掉，这类多半是
   图标或分隔线。
4. 输出屏幕行，形状与 Lens 相同（`ScreenOcrLine.toWire`）。Android 原生经通道
   `screenOcrUsesDartEngine` / `recognizeScreenOcrInDart` 取回（原名 `screenOcrUsesLens` /
   `recognizeScreenOcrLens`）。

推理会话在最后一次识别后保留 2 分钟，换模型时先关旧的。模型没下时先提示，再退回
系统 OCR。设置页选「本地」或换模型时会询问是否下载。

## 已知限制

- 通用 PP-OCR 权重的识别率没有在本仓的漫画基准上测过。转换验证里看到 tiny 会把
  「Łódź」读错，希腊文会丢重音，西里尔会漏「ї」。这些是权重本身的表现，与格式无关。
- 截屏识别在主 isolate 上做前后处理（解图在 `compute` 里），整屏一次是几百毫秒级的
  CPU 计算。
- 阿拉伯文没有逐字框。
