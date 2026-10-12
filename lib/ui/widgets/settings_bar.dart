import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../state/app_controller.dart';
import '../../theme.dart';

/// 参数栏（不同模式显示不同参数组）
class SettingsBar extends StatelessWidget {
  final AppController controller;
  const SettingsBar({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return Container(
      color: AppColors.panel,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: switch (c.mode) {
          ScanMode.document => _documentBar(c),
          ScanMode.book => _bookBar(c),
          ScanMode.idCard => _idCardBar(c),
          ScanMode.barcode => _barcodeBar(c),
          ScanMode.ocr => _ocrBar(c),
          _ => const SizedBox.shrink(),
        },
      ),
    );
  }

  Widget _documentBar(AppController c) {
    return Row(
      children: [
        LabeledSelect<CutMode>(
          label: '裁切方式',
          value: c.cutMode,
          items: CutMode.values,
          onChanged: (v) => c.setCutMode(v!),
        ),
        _check('智能修边', c.smartEdge, c.setSmartEdge),
        _check('去底色', c.removeBg, c.setRemoveBg),
        LabeledSelect<ColorEffect>(
          label: '输出效果',
          value: c.colorEffect,
          items: ColorEffect.values,
          onChanged: (v) => c.setColorEffect(v!),
        ),
        LabeledSelect<OutputFormat>(
          label: '输出格式',
          value: c.outputFormat,
          items: OutputFormat.values,
          onChanged: (v) => c.setOutputFormat(v!),
        ),
        LabeledSelect<NameStyle>(
          label: '命名方式',
          value: c.nameStyle,
          items: NameStyle.values,
          onChanged: (v) => c.setNameStyle(v!),
        ),
        _prefixField(c),
        _qualityControl(c),
      ],
    );
  }

  Widget _bookBar(AppController c) {
    return Row(
      children: [
        LabeledSelect<FlattenMode>(
          label: '展平方式',
          value: c.flattenMode,
          items: FlattenMode.values,
          onChanged: (v) => c.setFlattenMode(v!),
        ),
        LabeledSelect<ColorEffect>(
          label: '输出效果',
          value: c.colorEffect,
          items: ColorEffect.values,
          onChanged: (v) => c.setColorEffect(v!),
        ),
        LabeledSelect<OutputFormat>(
          label: '输出格式',
          value: c.outputFormat,
          items: OutputFormat.values,
          onChanged: (v) => c.setOutputFormat(v!),
        ),
        LabeledSelect<NameStyle>(
          label: '命名方式',
          value: c.nameStyle,
          items: NameStyle.values,
          onChanged: (v) => c.setNameStyle(v!),
        ),
        _prefixField(c),
        _qualityControl(c),
        const SizedBox(width: 10),
        _actionChip(Icons.auto_stories, '左右页一次拍摄', null),
      ],
    );
  }

  Widget _idCardBar(AppController c) {
    return Row(
      children: [
        _actionButton(Icons.nfc, '读取身份证', () => c.readIdCard()),
        const SizedBox(width: 10),
        _actionChip(Icons.badge_outlined, '支持读取信息 + 正反面合并照', null),
        if (c.lastIdCard != null) ...[
          const SizedBox(width: 14),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Text(
              '${c.lastIdCard!.name}  ${c.lastIdCard!.sex}  ${c.lastIdCard!.nation}  '
              '${c.lastIdCard!.cardNum}  ${c.lastIdCard!.effectedDate}',
              style: const TextStyle(fontSize: 12, color: AppColors.ok),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ],
    );
  }

  Widget _barcodeBar(AppController c) {
    return Row(
      children: [
        _actionButton(Icons.barcode_reader, '识别条码', () =>
            c.recognizeBarcode(qrcode: false)),
        const SizedBox(width: 10),
        _actionButton(Icons.qr_code_2, '识别二维码', () =>
            c.recognizeBarcode(qrcode: true)),
        const SizedBox(width: 14),
        SizedBox(
          width: 360,
          child: Text(
            c.lastBarcode.isEmpty ? '将条码/二维码放入画面后点击识别' : '识别结果: ${c.lastBarcode}',
            style: TextStyle(
                fontSize: 13,
                color: c.lastBarcode.isEmpty
                    ? AppColors.textDim
                    : AppColors.accent),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  Widget _ocrBar(AppController c) {
    return Row(
      children: [
        LabeledSelect<OcrLanguage>(
          label: '识别语言',
          value: c.ocrLanguage,
          items: OcrLanguage.values,
          onChanged: (v) => c.setOcrLanguage(v!),
        ),
        const SizedBox(width: 10),
        _actionButton(Icons.document_scanner, '识别上一张',
            () => c.ocrLastCapture()),
        const SizedBox(width: 14),
        SizedBox(
          width: 420,
          child: Text(
            c.ocrStatus.isNotEmpty
                ? c.ocrStatus
                : (c.lastOcrText.isEmpty
                    ? '拍摄后点击"识别上一张"进行OCR'
                    : c.lastOcrText),
            style: const TextStyle(fontSize: 12, color: AppColors.textDim),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  Widget _check(String label, bool value, ValueChanged<bool> onChanged) {
    return Padding(
      padding: const EdgeInsets.only(right: 14, left: 6),
      child: Row(
        children: [
          SizedBox(
            width: 16,
            height: 16,
            child: Checkbox(
              value: value,
              onChanged: (v) => onChanged(v ?? false),
              activeColor: AppColors.accent,
              side: const BorderSide(color: AppColors.textDim),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            ),
          ),
          const SizedBox(width: 5),
          Text(label,
              style: const TextStyle(fontSize: 13, color: AppColors.text)),
        ],
      ),
    );
  }

  Widget _prefixField(AppController c) {
    return Padding(
      padding: const EdgeInsets.only(right: 14, left: 6),
      child: Row(
        children: [
          const Text('前缀',
              style: TextStyle(fontSize: 13, color: AppColors.textDim)),
          const SizedBox(width: 6),
          SizedBox(
            width: 110,
            height: 30,
            child: TextField(
              style: const TextStyle(fontSize: 13, color: AppColors.text),
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Pic_',
                hintStyle:
                    const TextStyle(fontSize: 13, color: AppColors.textDim),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                enabledBorder: OutlineInputBorder(
                  borderSide:
                      const BorderSide(color: AppColors.divider, width: 1),
                  borderRadius: BorderRadius.circular(4),
                ),
                focusedBorder: OutlineInputBorder(
                  borderSide:
                      const BorderSide(color: AppColors.accent, width: 1),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              controller: TextEditingController(text: c.prefix)
                ..selection = TextSelection.collapsed(offset: c.prefix.length),
              onSubmitted: c.setPrefix,
              onChanged: c.setPrefix,
            ),
          ),
        ],
      ),
    );
  }

  Widget _qualityControl(AppController c) {
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: Row(
        children: [
          const Text('画质',
              style: TextStyle(fontSize: 13, color: AppColors.textDim)),
          SizedBox(
            width: 110,
            child: Slider(
              value: c.jpgQuality.toDouble(),
              min: 30,
              max: 100,
              divisions: 14,
              label: '${c.jpgQuality}',
              activeColor: AppColors.accent,
              inactiveColor: AppColors.divider,
              onChanged: (v) => c.setJpgQuality(v.round()),
            ),
          ),
          Text('${c.jpgQuality}',
              style: const TextStyle(fontSize: 12, color: AppColors.text)),
        ],
      ),
    );
  }

  Widget _actionButton(IconData icon, String label, VoidCallback onTap) {
    return Material(
      color: AppColors.card,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 15, color: AppColors.accent),
              const SizedBox(width: 6),
              Text(label,
                  style:
                      const TextStyle(fontSize: 13, color: AppColors.text)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _actionChip(IconData icon, String label, VoidCallback? onTap) {
    return Row(
      children: [
        Icon(icon, size: 14, color: AppColors.textDim),
        const SizedBox(width: 5),
        Text(label,
            style: const TextStyle(fontSize: 12, color: AppColors.textDim)),
      ],
    );
  }
}

/// 带标签的下拉选择
class LabeledSelect<T> extends StatelessWidget {
  final String label;
  final T value;
  final List<T> items;
  final ValueChanged<T?> onChanged;
  final String Function(T)? format;
  const LabeledSelect(
      {super.key,
      required this.label,
      required this.value,
      required this.items,
      required this.onChanged,
      this.format});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 14),
      child: Row(
        children: [
          Text(label,
              style: const TextStyle(fontSize: 13, color: AppColors.textDim)),
          const SizedBox(width: 6),
          Container(
            height: 30,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: AppColors.panelDark,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: AppColors.divider),
            ),
            child: DropdownButton<T>(
              value: value,
              isDense: true,
              underline: const SizedBox.shrink(),
              dropdownColor: AppColors.card,
              style:
                  const TextStyle(fontSize: 13, color: AppColors.text),
              items: [
                for (final it in items)
                  DropdownMenuItem(
                      value: it,
                      child: Text(format?.call(it) ?? _labelOf(it))),
              ],
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }

  String _labelOf(T it) {
    if (it is CutMode) return it.label;
    if (it is ColorEffect) return it.label;
    if (it is OutputFormat) return it.label;
    if (it is NameStyle) return it.label;
    if (it is FlattenMode) return it.label;
    if (it is OcrLanguage) return it.label;
    return '$it';
  }
}
