import 'package:flutter/widgets.dart';

import '../l10n/strings.dart';
import '../theme/niko_theme.dart';
import '../ui/controls.dart';
import '../ui/list.dart';

/// Built-in offline FAQ & troubleshooting reference (D-SET-31).
class FaqScreen extends StatelessWidget {
  const FaqScreen({super.key, required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final colors = NikoTheme.of(context);
    final strings = NikoStrings.of(Localizations.localeOf(context));
    final items = strings.faqEntries;

    return SingleChildScrollView(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 740),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(NikoSpace.s8, NikoSpace.s6, NikoSpace.s8, 40),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    NikoGhostButton(label: strings.whyBack, onPressed: onBack),
                    const SizedBox(width: NikoSpace.s3),
                    Expanded(
                      child: Text(
                        strings.faqTitle,
                        style: NikoType.title.style(colors.ink),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: NikoSpace.s2),
                Text(strings.faqSubtitle, style: NikoType.bodySm.style(colors.ink2)),
                const SizedBox(height: NikoSpace.s6),
                for (var i = 0; i < items.length; i++) ...[
                  if (i > 0) const SizedBox(height: NikoSpace.s4),
                  NikoSection(
                    overline: items[i].$1,
                    rows: [
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: NikoSpace.s4, vertical: NikoSpace.s4),
                        child: Text(items[i].$2, style: NikoType.body.style(colors.ink)),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
