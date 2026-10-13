import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../state/app_controller.dart';
import '../../theme.dart';

class SettingsBar extends StatefulWidget {
  final AppController controller;
  const SettingsBar({super.key, required this.controller});
  @override
  State<SettingsBar> createState() => _SettingsBarState();
}

class _SettingsBarState extends State<SettingsBar> {
  AppController get c => widget.controller;
  late final TextEditingController _prefix = TextEditingController(
    text: c.prefix,
  );
  @override
  void dispose() {
    _prefix.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final video = c.mode == ScanMode.video, ocr = c.mode == ScanMode.ocr;
    final book = c.mode == ScanMode.book, id = c.mode == ScanMode.idCard;
    return Container(
      color: AppColors.panel,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      child: IgnorePointer(
        ignoring: c.busy || c.recording || c.autoScan,
        child: Wrap(
          spacing: 20,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (!video && !ocr && !book)
              _select(
                '裁切方式',
                c.cutMode,
                CutMode.values
                    .where(
                      (v) =>
                          c.mode == ScanMode.document || v != CutMode.multiImg,
                    )
                    .toList(),
                c.setCutMode,
              ),
            if (book)
              _select(
                '展平方式',
                c.flattenMode,
                FlattenMode.values,
                c.setFlattenMode,
                format: (v) => v.label,
              ),
            if (book && c.flattenMode == FlattenMode.singlePage)
              _select(
                '扫描书页',
                c.bookPage,
                BookPage.values,
                c.setBookPage,
                format: (v) => v.label,
              ),
            if (book && c.flattenMode != FlattenMode.none)
              TextButton.icon(
                onPressed: c.resetBookSeam,
                icon: const Icon(Icons.center_focus_strong, size: 16),
                label: Text(c.bookSeamManual ? '重新识别中线' : '自动识别中线'),
              ),
            if (c.mode == ScanMode.document ||
                book ||
                c.mode == ScanMode.barcode) ...[
              _select(
                '扫描模式',
                c.autoMode,
                const [false, true],
                c.setAutoMode,
                format: (v) => v ? '自动' : '手动',
              ),
              if (c.autoMode)
                _select(
                  '静止倒计时',
                  c.autoDelaySeconds,
                  List.generate(10, (i) => i + 1),
                  c.setAutoDelay,
                  format: (v) => '$v 秒',
                ),
            ],
            if (!video && !ocr)
              _select(
                '输出效果',
                c.colorEffect,
                c.availableColorEffects,
                c.setColorEffect,
              ),
            if (c.mode == ScanMode.document || book)
              _select(
                '扫描页面',
                c.multiPage,
                const [false, true],
                c.setMultiPage,
                format: (v) => v ? '多页 PDF' : '单页',
              ),
            if (!video)
              _select(
                '输出格式',
                c.outputFormat,
                c.availableFormats,
                c.setOutputFormat,
              ),
            if (video) ...[
              _select(
                '录制来源',
                c.recordSource,
                RecordSource.values,
                c.setRecordSource,
              ),
              _select(
                '录制格式',
                c.recordFormat,
                RecordFormat.values,
                c.setRecordFormat,
                format: (v) => v.label,
              ),
            ],
            if (!id &&
                !video &&
                c.mode != ScanMode.contract &&
                c.mode != ScanMode.barcode)
              _select(
                '识别语言',
                c.ocrLanguage,
                OcrLanguage.values,
                c.setOcrLanguage,
              ),
            if (!ocr)
              _select(
                '命名方式',
                c.nameStyle,
                c.availableNameStyles,
                c.setNameStyle,
              ),
            if (!ocr)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    '前缀',
                    style: TextStyle(fontSize: 13, color: AppColors.textDim),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 120,
                    height: 32,
                    child: TextField(
                      key: const Key('filename-prefix'),
                      controller: _prefix,
                      style: const TextStyle(fontSize: 13),
                      onChanged: c.setPrefix,
                      decoration: const InputDecoration(
                        isDense: true,
                        filled: true,
                        fillColor: AppColors.panelDark,
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 9,
                        ),
                        border: OutlineInputBorder(),
                        hintText: 'Pic_',
                      ),
                    ),
                  ),
                ],
              ),
            if (c.mode == ScanMode.document ||
                id ||
                c.mode == ScanMode.contract)
              _check('智能修边', c.smartEdge, c.setSmartEdge),
            if (id) ...[
              _check('正反面合并', c.mergeIdSides, c.setMergeIdSides),
              if (!Platform.isMacOS)
                TextButton.icon(
                  onPressed: c.connected ? c.readIdCard : null,
                  icon: const Icon(Icons.nfc, size: 16),
                  label: const Text('读取身份证'),
                ),
            ],
            if (c.mode == ScanMode.barcode) ...[
              _select('识别类型', c.qrcode, [false, true], (v) {
                c.qrcode = v;
                c.notifyListeners();
              }, format: (v) => v ? '二维码' : '条码'),
              TextButton.icon(
                onPressed: () => c.recognizeBarcode(qrcode: c.qrcode),
                icon: const Icon(Icons.qr_code_scanner, size: 16),
                label: const Text('开始识别'),
              ),
              if (c.lastBarcode.isNotEmpty)
                SizedBox(
                  width: 240,
                  child: SelectableText(
                    c.lastBarcode,
                    style: const TextStyle(
                      color: AppColors.accent,
                      fontSize: 13,
                    ),
                  ),
                ),
            ],
            if (ocr) ...[
              TextButton.icon(
                onPressed: c.currentPage != null ? c.ocrLastCapture : null,
                icon: const Icon(Icons.text_snippet_outlined, size: 16),
                label: const Text('识别所选图片'),
              ),
              TextButton.icon(
                onPressed: c.lastOcrText.isNotEmpty ? c.exportOcr : null,
                icon: const Icon(Icons.save_alt, size: 16),
                label: const Text('导出文字'),
              ),
            ],
            if (c.mode == ScanMode.contract) ...[
              _markButton(false),
              _markButton(true),
              _select('签章位置', c.markCorner, [0, 1, 2, 3], (v) {
                c.markCorner = v;
                c.notifyListeners();
              }, format: (v) => ['左上', '右上', '左下', '右下'][v]),
              _select('签章尺寸', c.markSize, [.1, .2, .3, .4], (v) {
                c.markSize = v;
                c.notifyListeners();
              }, format: (v) => '${(v * 100).round()}%'),
            ],
          ],
        ),
      ),
    );
  }

  Widget _markButton(bool stamp) {
    final active = (stamp ? c.stampBytes : c.signatureBytes) != null;
    return TextButton.icon(
      onPressed: () async {
        final file = await openFile(
          acceptedTypeGroups: [
            const XTypeGroup(
              label: '签名 / 印章图片',
              extensions: ['png', 'jpg', 'jpeg', 'bmp'],
            ),
          ],
        );
        if (file != null) c.setMark(await file.readAsBytes(), stamp: stamp);
      },
      icon: Icon(
        stamp ? Icons.approval_outlined : Icons.draw_outlined,
        size: 16,
      ),
      label: Text('${active ? '更换' : '添加'}${stamp ? '印章' : '签名'}'),
    );
  }

  Widget _select<T>(
    String label,
    T value,
    List<T> items,
    ValueChanged<T> changed, {
    String Function(T)? format,
  }) => LabeledSelect<T>(
    label: label,
    value: value,
    items: items,
    onChanged: (v) {
      if (v != null) changed(v);
    },
    format: format,
  );
  Widget _check(String label, bool value, ValueChanged<bool> changed) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      SizedBox(
        width: 24,
        height: 28,
        child: Checkbox(
          value: value,
          onChanged: (v) => changed(v ?? false),
          visualDensity: VisualDensity.compact,
        ),
      ),
      const SizedBox(width: 4),
      Text(label, style: const TextStyle(fontSize: 13)),
    ],
  );
}

class LabeledSelect<T> extends StatelessWidget {
  final String label;
  final T value;
  final List<T> items;
  final ValueChanged<T?> onChanged;
  final String Function(T)? format;
  const LabeledSelect({
    super.key,
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
    this.format,
  });
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (label.isNotEmpty) ...[
        Text(
          label,
          style: const TextStyle(fontSize: 13, color: AppColors.textDim),
        ),
        const SizedBox(width: 8),
      ],
      Container(
        height: 32,
        width: 138,
        padding: const EdgeInsets.symmetric(horizontal: 9),
        decoration: BoxDecoration(
          color: AppColors.panelDark,
          borderRadius: BorderRadius.circular(3),
          border: Border.all(color: AppColors.divider),
        ),
        child: DropdownButton<T>(
          value: items.contains(value) ? value : items.firstOrNull,
          isExpanded: true,
          isDense: true,
          underline: const SizedBox.shrink(),
          dropdownColor: AppColors.card,
          style: const TextStyle(fontSize: 13, color: AppColors.text),
          items: [
            for (final it in items)
              DropdownMenuItem(
                value: it,
                child: Text(
                  format?.call(it) ?? _label(it),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: onChanged,
        ),
      ),
    ],
  );
  String _label(T value) => switch (value) {
    CutMode v => v.label,
    ColorEffect v => v.label,
    OutputFormat v => v.label,
    NameStyle v => v.label,
    FlattenMode v => v.label,
    OcrLanguage v => v.label,
    RecordFormat v => v.label,
    RecordSource v => v.label,
    _ => '$value',
  };
}
