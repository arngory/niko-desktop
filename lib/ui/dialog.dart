import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../theme/niko_theme.dart';
import 'banner.dart';
import 'controls.dart';
import 'icons.dart';

/// A modal dialog over the current screen (m-dialog): scrim, surface-1 card with radius-md, headline, body, optional
/// error banner, and Cancel/Save actions. Explicitly requests focus into its own [FocusScopeNode] so Tab stays inside
/// and Escape closes the dialog even when focus started in the header.
class NikoDialog extends StatefulWidget {
  const NikoDialog({
    super.key,
    required this.title,
    required this.body,
    required this.cancelLabel,
    required this.saveLabel,
    required this.onClose,
    required this.onSave,
    this.errorTitle = '',
    this.error = '',
    this.maxWidth = 480,
  });

  final String title;
  final Widget body;
  final String cancelLabel;
  final String saveLabel;
  final VoidCallback onClose;
  final VoidCallback? onSave;
  final String errorTitle;
  final String error;
  final double maxWidth;

  @override
  State<NikoDialog> createState() => _NikoDialogState();
}

class _NikoDialogState extends State<NikoDialog> {
  final _scope = FocusScopeNode();

  @override
  void initState() {
    super.initState();
    // autofocus is skipped when an outer scope (such as the header) already holds focus
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scope.requestFocus();
    });
  }

  @override
  void dispose() {
    _scope.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = NikoTheme.of(context);
    return Shortcuts(
      shortcuts: const {SingleActivator(LogicalKeyboardKey.escape): DismissIntent()},
      child: Actions(
        actions: {DismissIntent: CallbackAction<DismissIntent>(onInvoke: (_) => widget.onClose())},
        child: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(onTap: widget.onClose, child: ColoredBox(color: colors.scrim)),
            ),
            Center(
              child: FocusScope(
                node: _scope,
                autofocus: true,
                child: Semantics(
                  scopesRoute: true,
                  namesRoute: true,
                  explicitChildNodes: true,
                  label: widget.title,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: widget.maxWidth),
                    child: Padding(
                      padding: const EdgeInsets.all(NikoSpace.s5),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: colors.surface1,
                          borderRadius: BorderRadius.circular(NikoRadius.md),
                        ),
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.all(NikoSpace.s6),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Semantics(
                                header: true,
                                child: Text(widget.title, style: NikoType.headline.style(colors.ink)),
                              ),
                              const SizedBox(height: NikoSpace.s5),
                              widget.body,
                              if (widget.error.isNotEmpty) ...[
                                NikoBanner(
                                  icon: NikoIcons.alert,
                                  title: widget.errorTitle,
                                  text: widget.error,
                                  danger: true,
                                ),
                                const SizedBox(height: NikoSpace.s4),
                              ],
                              Row(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  NikoGhostButton(label: widget.cancelLabel, onPressed: widget.onClose),
                                  const SizedBox(width: NikoSpace.s2),
                                  NikoPrimaryButton(label: widget.saveLabel, onPressed: widget.onSave),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
