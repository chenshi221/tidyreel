import '../model/media.dart';
import '../model/naming.dart';

/// Owner: Agent D. PLAN §3.1.

/// File-name template (no extension) for [kind] ([MediaKind.movie] or [MediaKind.episode]).
String compileTemplate(NamingOptions options, MediaKind kind) =>
    throw UnimplementedError('Agent D');

/// Fills `{var}`, `{var:02}` and optional `[ ... ]` segments.
String renderTemplate(String template, Map<String, Object?> vars) =>
    throw UnimplementedError('Agent D');

/// Replaces characters illegal on Windows / cloud drives; trims trailing dots and spaces.
String sanitizeName(String name) => throw UnimplementedError('Agent D');
