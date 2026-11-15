#!/usr/bin/env python3
"""Catch the mistakes a Swift compiler would, without a Swift compiler.

The app only compiles on macOS (SwiftUI, UIKit and the iPhoneOS SDK), so anywhere else the first real check is a CI
run. This script is the step before that: it parses every source with tree-sitter and checks the things that have
actually broken builds, in seconds:

  syntax        anything that does not parse
  members       Type.member and instance.member on the app's OWN types: the member has to be declared somewhere —
                in the type, an extension of it, an app superclass or an app protocol it adopts
                (caught: Library.devices(), when the function is Library.scan())
  labels        a call to an app method has to match one of its declared overloads' argument labels
  shadowing     a bare call to a system function (send, write, close, ...) inside a type that declares a method of
                the same name resolves to the method, not the system call
                (caught: send(fd, ...) inside a class with a send(ep:...) method)
  availability  APIs newer than the deployment target (iOS 16), outside an `if #available` block
  int32         emulator calls that return Int32/UInt64, bound to a name: listed, so a mix-up with Int is looked at
                (caught: backlight = level, where level came back as Int32)

It deliberately does not check the SDK's own types (URL, Data, View ...): that needs the SDK. Errors exit 1;
warnings are printed and exit 0.

    python3 ios/scripts/precheck.py ios/App/Sources
"""
import os
import re
import sys

import tree_sitter_swift as ts
from tree_sitter import Language, Parser

PARSER = Parser(Language(ts.language()))

# Members every type has, or that well-known protocol conformances add.
UNIVERSAL = {
    "init", "self", "Type", "rawValue", "allCases", "hashValue", "hash", "description", "debugDescription", "id",
    "objectWillChange", "wrappedValue", "projectedValue", "localizedDescription", "body",
}
# Protocols that add nothing a precheck needs to know about beyond UNIVERSAL.
KNOWN_PROTOCOLS = {
    "ObservableObject", "Sendable", "Equatable", "Hashable", "Identifiable", "CaseIterable", "Codable", "Decodable",
    "Encodable", "CustomStringConvertible", "CustomDebugStringConvertible", "Error", "LocalizedError", "View",
    "UIViewRepresentable", "UIViewControllerRepresentable", "App", "Comparable", "RawRepresentable",
    "DynamicProperty", "Shape", "ViewModifier", "Scene", "PreviewProvider", "ShapeStyle", "AnyObject",
    "String", "Int", "UInt8", "UInt16", "UInt32", "Int32", "Double",  # raw types of enums
}
# System functions a method can hide (the build that failed on `send`).
SYSTEM_FUNCS = {
    "send", "recv", "read", "write", "close", "open", "bind", "listen", "accept", "connect", "socket", "poll",
    "select", "shutdown", "free", "malloc", "sleep", "usleep", "exit", "abort", "min", "max", "abs", "strerror",
    "getsockname", "setsockopt", "fcntl", "dlsym", "dlopen", "chmod", "unlink", "rename", "stat", "print", "kill",
}
# Newer than iOS 16. Each is a regex over a line.
IOS17 = [
    (r"\.onChange\(of:[^)]*\)\s*\{\s*\w+\s*,\s*\w+\s+in", ".onChange with two closure parameters (iOS 17)"),
    (r"\.onChange\(of:[^)]*initial:", ".onChange(initial:) (iOS 17)"),
    (r"@Observable\b", "@Observable (iOS 17)"),
    (r"@Bindable\b", "@Bindable (iOS 17)"),
    (r"\bContentUnavailableView\b", "ContentUnavailableView (iOS 17)"),
    (r"\.sensoryFeedback\(", ".sensoryFeedback (iOS 17)"),
    (r"\.scrollPosition\(", ".scrollPosition (iOS 17)"),
    (r"\.containerRelativeFrame\(", ".containerRelativeFrame (iOS 17)"),
    (r"\.contentMargins\(", ".contentMargins (iOS 17)"),
    (r"\.symbolEffect\(", ".symbolEffect (iOS 17)"),
    (r"\.phaseAnimator\(", ".phaseAnimator (iOS 17)"),
    (r"\.keyframeAnimator\(", ".keyframeAnimator (iOS 17)"),
    (r"\.inspector\(", ".inspector (iOS 17)"),
    (r"\.scrollTargetBehavior\(", ".scrollTargetBehavior (iOS 17)"),
    (r"\.safeAreaPadding\(", ".safeAreaPadding (iOS 17)"),
    (r"\.defaultScrollAnchor\(", ".defaultScrollAnchor (iOS 17)"),
    (r"\.onKeyPress\(", ".onKeyPress (iOS 17)"),
    (r"\.scrollClipDisabled\(", ".scrollClipDisabled (iOS 17)"),
    (r"\.topBarTrailing\b|\.topBarLeading\b", "toolbar placement .topBarLeading/.topBarTrailing (iOS 17)"),
    (r"\.navigationDestination\(item:", ".navigationDestination(item:) (iOS 17)"),
]


# Valid Swift that tree-sitter-swift 0.7 can't parse. Each is blanked to the same length before parsing, so lines and
# byte offsets stay put; nothing the checks look at lives inside them.
#   (@convention(c) (A) -> B).self     a function type's metatype      -> T.self, padded
#   @_silgen_name("x") func f(...) -> R  a declaration without a body   -> blank
#   .success(())                         an empty tuple argument        -> .success(0 )


def _blank(b):
    return bytes(c if c in b"\n" else 32 for c in b)


def parseable(src):
    out = bytearray(src)
    i = 0
    while True:
        i = src.find(b"(@convention(c)", i)
        if i < 0:
            break
        depth, j = 0, i
        while j < len(src):
            depth += {40: 1, 41: -1}.get(src[j], 0)
            if depth == 0:
                break
            j += 1
        end = j + 1
        if src[end:end + 5] == b".self":
            out[i:end] = b"T" + _blank(src[i + 1:end])
        i = end
    src = bytes(out)
    src = re.sub(rb'@_silgen_name\("[^"]*"\)\s*\n[^\n]*', lambda m: _blank(m.group(0)), src)
    src = src.replace(b".success(())", b".success(0 )")
    return src


def runtime_returns(raw):
    """QemuRuntime's C symbols and what they return, read from the declarations' text."""
    out = {}
    for m in re.finditer(rb"lazy var (\w+) = (?:optionalSym|sym)\(", raw):
        decl = raw[m.end():raw.find(b".self)", m.end())].decode("utf-8", "replace")
        r = re.search(r"->\s*([\w<>?]+)\)?\s*$", decl)
        if r:
            out[m.group(1).decode()] = r.group(1)
    return out


def text(src, node):
    return src[node.start_byte:node.end_byte].decode("utf-8", "replace")


def line_of(node):
    return node.start_point[0] + 1


class TypeInfo:
    def __init__(self, name):
        self.name = name
        self.primary = False          # declared (not only extended) in the app
        self.kind = None
        self.members = set()
        self.funcs = {}               # name -> [ [(label, has_default), ...], ... ]
        self.props = {}               # name -> declared type name (simple), or None
        self.props_raw = {}           # name -> annotation text ("Int", "Double?")
        self.plain_props = set()      # properties that are not closures: calling one is an error
        self.supers = set()           # inheritance list
        self.open = False             # inherits from a type outside the app: members can't be checked


class Index:
    def __init__(self):
        self.types = {}
        self.protocols = {}           # app protocol -> TypeInfo (members from its extensions too)
        self.runtime_returns = {}     # QemuRuntime member -> C return type
        self.globals = set()          # free functions the app declares

    def info(self, name):
        if name not in self.types:
            self.types[name] = TypeInfo(name)
        return self.types[name]


# ---------------------------------------------------------------------------------------------------------------------
# Indexing


def type_name_of(src, node):
    """The simple name of a declaration (or of the type an extension extends)."""
    name = node.child_by_field_name("name")
    if name is None:
        return None
    if name.type == "type_identifier":
        return text(src, name)
    ids = [c for c in walk(name) if c.type == "type_identifier"]
    return text(src, ids[-1]) if ids else text(src, name)


def walk(node):
    yield node
    for c in node.children:
        yield from walk(c)


def simple_type(src, node):
    """user_type / optional_type / implicitly unwrapped -> the last simple type name."""
    if node is None:
        return None
    if node.type in ("user_type", "type_identifier"):
        ids = [c for c in walk(node) if c.type == "type_identifier"]
        return text(src, ids[-1]) if ids else None
    if node.type == "optional_type":
        return simple_type(src, node.child_by_field_name("wrapped"))
    if node.type in ("array_type", "dictionary_type", "function_type", "tuple_type"):
        return None             # [Foo] is an Array, not a Foo
    if node.type not in ("type_annotation", "inheritance_specifier"):
        return None
    for c in node.children:
        if c.type in ("user_type", "optional_type", "type_identifier"):
            return simple_type(src, c)
    return None


def params_of(src, func):
    out = []
    for c in func.children:
        if c.type != "parameter":
            continue
        ext = c.child_by_field_name("external_name")
        name = c.child_by_field_name("name")
        label = text(src, ext) if ext is not None else (text(src, name) if name is not None else None)
        if label == "_":
            label = None
        has_default = any(ch.type == "=" for ch in c.children) or "=" in text(src, c).split(":")[-1]
        # A default value is a sibling of the parameter in tree-sitter-swift: look at the next tokens.
        out.append([label, has_default])
    # tree-sitter-swift puts `= default` after the parameter node, as siblings of it.
    kids = list(func.children)
    for i, c in enumerate(kids):
        if c.type == "parameter" and i + 1 < len(kids) and kids[i + 1].type == "=":
            pos = sum(1 for k in kids[:i] if k.type == "parameter")
            out[pos][1] = True
    # A variadic parameter (`_ keys: String...`) takes any number of arguments: no label check for this overload.
    if any(c.type == "parameter" and text(src, c).rstrip().endswith("...") for c in func.children):
        return None
    return [tuple(p) for p in out]


def index_body(src, idx, info, body):
    for member in body.children:
        t = member.type
        if t == "function_declaration":
            n = member.child_by_field_name("name")
            if n is not None:
                fname = text(src, n)
                info.members.add(fname)
                info.funcs.setdefault(fname, []).append(params_of(src, member))
        elif t == "init_declaration":
            info.members.add("init")
            info.funcs.setdefault("init", []).append(params_of(src, member))
        elif t == "property_declaration":
            for pat in member.children:
                if pat.type == "pattern":
                    for b in walk(pat):
                        if b.type == "simple_identifier":
                            pname = text(src, b)
                            info.members.add(pname)
                            ann = next((c for c in member.children if c.type == "type_annotation"), None)
                            ptype = simple_type(src, ann.child_by_field_name("name")) if ann is not None else None
                            if ann is not None and text(src, ann).rstrip().endswith(("?", "!")):
                                ptype = None    # an Optional: .map, .flatMap and ?? are the Optional's, not the type's
                            if ptype is None:
                                value = member.child_by_field_name("value")
                                if value is not None and value.type == "call_expression":
                                    callee = value.children[0]
                                    if callee.type == "simple_identifier":
                                        ptype = text(src, callee)
                                    elif callee.type == "navigation_expression":
                                        pass
                            info.props[pname] = ptype
                            ann_text = text(src, ann) if ann is not None else ""
                            if ann is not None:
                                info.props_raw[pname] = ann_text.lstrip(":").strip()
                            else:
                                v = member.child_by_field_name("value")
                                if v is not None and v.type == "integer_literal":
                                    info.props_raw[pname] = "Int"
                                elif v is not None and v.type == "real_literal":
                                    info.props_raw[pname] = "Double"
                            if ann is not None and "->" not in ann_text and "Optional<" not in ann_text:
                                info.plain_props.add(pname)
                            break
        elif t == "enum_entry":
            for c in member.children:
                if c.type == "simple_identifier":
                    info.members.add(text(src, c))
        elif t in ("class_declaration", "protocol_declaration", "typealias_declaration"):
            nn = type_name_of(src, member)
            if nn:
                info.members.add(nn)
            if t == "class_declaration":
                index_decl(src, idx, member, parent=info.name)
        elif t == "subscript_declaration":
            info.members.add("subscript")


def index_decl(src, idx, node, parent=None):
    kind_node = node.child_by_field_name("declaration_kind")
    kind = text(src, kind_node) if kind_node is not None else None
    name = type_name_of(src, node)
    if not name:
        return
    if parent:
        # A nested type is only visible by its simple name inside its parent; elsewhere the simple name means
        # something else (Reports.Context is not SwiftUI's Context). Index it qualified, so nothing outside resolves to it.
        name = parent + "." + name
    info = idx.info(name)
    if kind != "extension":
        info.primary = True
        info.kind = kind
    for c in node.children:
        if c.type == "inheritance_specifier":
            sup = simple_type(src, c)
            if sup:
                info.supers.add(sup)
    body = node.child_by_field_name("body")
    if body is not None:
        index_body(src, idx, info, body)


def index_protocol(src, idx, node):
    name = type_name_of(src, node)
    if not name:
        return
    info = idx.info(name)
    info.primary = True
    info.kind = "protocol"
    body = node.child_by_field_name("body")
    if body is not None:
        for c in walk(body):
            if c.type in ("protocol_function_declaration", "function_declaration"):
                n = c.child_by_field_name("name")
                if n is not None:
                    info.members.add(text(src, n))
            if c.type == "protocol_property_declaration":
                for b in walk(c):
                    if b.type == "simple_identifier":
                        info.members.add(text(src, b))
                        break
    idx.protocols[name] = info


def finish(idx):
    """Resolve inheritance: members of app supertypes count; a non-app superclass makes the type open."""
    def resolve(info, seen):
        if info.name in seen:
            return info.members
        seen.add(info.name)
        members = set(info.members)
        for sup in info.supers:
            if sup in idx.types and idx.types[sup].primary:
                members |= resolve(idx.types[sup], seen)
            elif sup not in KNOWN_PROTOCOLS:
                info.open = True
        return members

    for info in idx.types.values():
        info.all_members = resolve(info, set())


# ---------------------------------------------------------------------------------------------------------------------
# Checks


class Report:
    def __init__(self):
        self.errors = []
        self.warnings = []

    def error(self, f, line, msg):
        self.errors.append(f"{f}:{line}: error: {msg}")

    def warn(self, f, line, msg):
        self.warnings.append(f"{f}:{line}: warning: {msg}")


def is_subscript(src, call):
    suffix = next((c for c in call.children if c.type == "call_suffix"), None)
    args = next((c for c in suffix.children if c.type == "value_arguments"), None) if suffix is not None else None
    return args is not None and text(src, args).startswith("[")


def call_labels(src, call):
    suffix = next((c for c in call.children if c.type == "call_suffix"), None)
    if suffix is None or is_subscript(src, call):
        return None, False
    labels = []
    trailing = False
    for c in suffix.children:
        if c.type == "value_arguments":
            for arg in c.children:
                if arg.type == "value_argument":
                    lab = arg.child_by_field_name("name")
                    labels.append(text(src, lab).rstrip(":").strip() if lab is not None else None)
        elif c.type in ("lambda_literal", "annotated_lambda"):
            trailing = True
    # tree-sitter-swift hangs `try await f(x) { ... }`'s closure on an outer call around the try/await.
    n = call
    while n.parent is not None and n.parent.type in ("await_expression", "try_expression"):
        n = n.parent
    outer = n.parent
    if outer is not None and outer.type == "call_expression" and outer.children and outer.children[0] == n:
        for c in outer.children:
            if c.type == "call_suffix" and any(k.type == "lambda_literal" for k in c.children):
                trailing = True
    return labels, trailing


def matches(params, labels, trailing):
    """Can these call labels fill this parameter list (defaults may be skipped, a trailing closure fills the rest)?"""
    if params is None:      # variadic
        return True
    i = 0
    for lab in labels:
        while i < len(params) and params[i][0] != lab and params[i][1]:
            i += 1
        if i >= len(params) or params[i][0] != lab:
            return False
        i += 1
    remaining = params[i:]
    if trailing:
        return len(remaining) >= 1 or True
    return all(p[1] for p in remaining)


def scopes_for(src, node, idx):
    """Names in scope at `node` that have a known app type: the enclosing types' properties, then the enclosing
    function's parameters and locals (inner wins)."""
    chain = []
    n = node
    while n is not None:
        chain.append(n)
        n = n.parent
    names = {}
    for anc in reversed(chain):
        if anc.type == "class_declaration":
            tn = type_name_of(src, anc)
            if tn in idx.types:
                for p, t in idx.types[tn].props.items():
                    if t:
                        names[p] = t
        elif anc.type in ("function_declaration", "init_declaration"):
            for c in anc.children:
                if c.type == "parameter":
                    nm = c.child_by_field_name("name")
                    tt = None
                    for cc in c.children:
                        if cc.type in ("user_type", "optional_type"):
                            tt = simple_type(src, cc)
                    if nm is not None and tt:
                        names[text(src, nm)] = tt
            body = anc.child_by_field_name("body")
            if body is not None:
                for d in walk(body):
                    if d.type == "property_declaration" and d.start_byte < node.start_byte:
                        pat = next((c for c in d.children if c.type == "pattern"), None)
                        if pat is None:
                            continue
                        nm = next((b for b in walk(pat) if b.type == "simple_identifier"), None)
                        if nm is None:
                            continue
                        ann = next((c for c in d.children if c.type == "type_annotation"), None)
                        tt = simple_type(src, ann.child_by_field_name("name")) if ann is not None else None
                        value = d.child_by_field_name("value")
                        if tt is None and value is not None and value.type == "call_expression" and \
                                value.children[0].type == "simple_identifier":
                            tt = text(src, value.children[0])
                        # Any other binding (a closure parameter, a computed value) hides the outer name.
                        names[text(src, nm)] = tt
        elif anc.type == "lambda_literal":
            # Closure parameters hide outer names; we don't know their types.
            for d in walk(anc):
                if d.type == "lambda_parameter":
                    nm = next((b for b in walk(d) if b.type == "simple_identifier"), None)
                    if nm is not None:
                        names[text(src, nm)] = None
                if d.type == "statements":
                    break
    return names


def local_funcs(src, node):
    """Functions declared inside the enclosing function bodies (nested funcs shadow the type's methods)."""
    names = set()
    n = node.parent
    while n is not None and n.type != "class_declaration":
        if n.type == "function_body" or n.type == "statements":
            for c in n.children:
                if c.type == "function_declaration":
                    nm = c.child_by_field_name("name")
                    if nm is not None:
                        names.add(text(src, nm))
        n = n.parent
    return names


def enclosing_type(src, node):
    n = node.parent
    while n is not None:
        if n.type == "class_declaration":
            return type_name_of(src, n)
        n = n.parent
    return None


def in_available_block(src, node):
    n = node.parent
    while n is not None:
        if n.type == "if_statement" and "#available(iOS 17" in text(src, n)[:60]:
            return True
        n = n.parent
    return False


# Names the SDKs already use: an app type nested under one of these names (PackedDevice.Index.Image) doesn't stop the
# simple name meaning SwiftUI's or Swift's own elsewhere.
SDK_TYPES = {
    "Image", "Result", "Context", "Text", "Label", "Button", "Color", "State", "Data", "URL", "Date", "Error", "Kind",
    "Status", "Options", "Mode", "Entry", "Item", "Section", "Group", "Link", "Shape", "Path", "Font", "Event",
    "Value", "Key", "Element", "Index", "Range", "Style", "Content", "Body", "Configuration", "Coordinator", "Task",
    "Timer", "Thread", "Notification", "Bundle", "Picker", "Toggle", "Menu", "Form", "List", "Table", "Grid",
    "Stack", "Layout", "Animation", "Transaction", "Binding", "Environment", "Scene", "Window", "View", "Model",
}


def check_file(path, src, tree, idx, report):
    short = os.path.relpath(path)
    for node in walk(tree.root_node):
        # ---- members: X.member on app types
        if node.type == "navigation_expression":
            target = node.child_by_field_name("target")
            suffix = node.child_by_field_name("suffix")
            if target is None or suffix is None or target.type not in ("simple_identifier", "self_expression"):
                continue
            member_node = suffix.child_by_field_name("suffix")
            if member_node is None or member_node.type != "simple_identifier":
                continue
            tname = text(src, target)
            member = text(src, member_node)
            if target.type == "self_expression":
                tname = enclosing_type(src, node) or "self"
            # A type name used directly (Library.scan), or a variable whose type we know (controls.rotate).
            if tname in idx.types and idx.types[tname].primary and tname[:1].isupper():
                resolved = tname
            else:
                resolved = scopes_for(src, node, idx).get(tname)
            if not resolved or resolved not in idx.types:
                continue
            info = idx.types[resolved]
            if not info.primary or info.open:
                continue
            parent = node.parent
            if parent is not None and parent.type == "call_expression" and not is_subscript(src, parent) \
                    and member in info.plain_props \
                    and member not in info.funcs and not info.open:
                report.error(short, line_of(node), f"{resolved}.{member} is a property, not a function — "
                                                   f"it can't be called with ()")
                continue
            if member in info.all_members or member in UNIVERSAL:
                # ---- labels: a call to a declared method has to match an overload
                parent = node.parent
                if parent is not None and parent.type == "call_expression" and member in info.funcs:
                    labels, trailing = call_labels(src, parent)
                    if labels is not None and not any(matches(p, labels, trailing) for p in info.funcs[member]):
                        sigs = [
                            "(" + ", ".join((lab or "_") + ":" for lab, _ in p) + ")" for p in info.funcs[member] if p
                        ]
                        got = "(" + ", ".join((lab or "_") + ":" for lab in labels) + ")"
                        report.error(short, line_of(node),
                                     f"{resolved}.{member}{got} matches none of its declarations {' '.join(sigs)}")
                continue
            close = sorted(m for m in info.all_members if m.lower().startswith(member[:3].lower()))[:4]
            hint = f" (did you mean {', '.join(close)}?)" if close else ""
            what = "type" if tname == resolved else f"'{tname}' ({resolved})"
            report.error(short, line_of(node), f"{what} has no member '{member}'{hint}")

        # ---- shadowing: a bare system call inside a type with a method of that name
        elif node.type == "call_expression" and node.children and node.children[0].type == "simple_identifier":
            fname = text(src, node.children[0])
            owner = enclosing_type(src, node)
            if not owner or owner not in idx.types or fname not in idx.types[owner].funcs:
                continue
            if fname in local_funcs(src, node):
                continue
            labels, trailing = call_labels(src, node)
            if labels is None or any(matches(p, labels, trailing) for p in idx.types[owner].funcs[fname]):
                continue
            if fname in SYSTEM_FUNCS:
                report.error(short, line_of(node),
                             f"'{fname}(...)' here resolves to {owner}.{fname}, not the system call — "
                             f"rename the method")
            elif fname not in idx.globals:
                sigs = ["(" + ", ".join((lab or "_") + ":" for lab, _ in p) + ")" for p in idx.types[owner].funcs[fname] if p]
                got = "(" + ", ".join((lab or "_") + ":" for lab in labels) + ")"
                report.error(short, line_of(node),
                             f"{owner}.{fname}{got} matches none of its declarations {' '.join(sigs)}")

    # ---- nested types: a type declared inside another (GuestAgent.InstallFailure) is only in scope by its simple
    # name inside that type and its extensions; anywhere else the simple name is "cannot find in scope".
    nested = {}
    for qualified, info in idx.types.items():
        if "." in qualified and info.primary:
            parent, simple = qualified.rsplit(".", 1)
            nested.setdefault(simple, []).append(parent)
    for node in walk(tree.root_node):
        if node.type != "call_expression" or not node.children or node.children[0].type != "simple_identifier":
            continue
        name = text(src, node.children[0])
        if not name[:1].isupper() or name not in nested or (name in idx.types and idx.types[name].primary) \
                or name in SDK_TYPES:
            continue
        inside = set()
        n = node.parent
        while n is not None:
            if n.type in ("class_declaration", "protocol_declaration"):
                tn = type_name_of(src, n)
                if tn:
                    inside.add(tn)
            n = n.parent
        parents = nested[name]
        if not any(p.rsplit(".", 1)[-1] in inside for p in parents):
            report.error(short, line_of(node), f"'{name}' is declared inside {' / '.join(parents)}: "
                                               f"here it has to be written {parents[0]}.{name}")

    # ---- availability
    lines = src.decode("utf-8", "replace").split("\n")
    for i, line in enumerate(lines):
        if line.strip().startswith("//"):
            continue
        for pattern, what in IOS17:
            if re.search(pattern, line):
                # Find a node on this line to ask whether it sits inside `if #available(iOS 17`.
                guarded = "#available(iOS 17" in "\n".join(lines[max(0, i - 6):i + 1])
                if not guarded:
                    report.error(short, i + 1, f"{what}, but the app targets iOS 16")

    # ---- int32: a value the emulator returned as Int32/UInt64 stored into an app property declared Int/Double
    for node in walk(tree.root_node):
        if node.type not in ("function_declaration", "lambda_literal", "computed_property"):
            continue
        body = text(src, node)
        bound = {}
        for m in re.finditer(r"\b(?:let|var)\s+(\w+)\s*=\s*(?:self\.)?(?:qemu|runtime)\??\.(\w+)\??\(", body):
            ret = idx.runtime_returns.get(m.group(2))
            if ret in ("Int32", "UInt64", "UInt32", "Int64"):
                bound[m.group(1)] = (m.group(2), ret)
        if not bound:
            continue
        owner = enclosing_type(src, node)
        props = idx.types[owner].props_raw if owner in idx.types else {}
        for m in re.finditer(r"(?:self\.)?\b(\w+)\s*(?<![=!<>])=(?!=)\s*(\w+)\b(?!\s*[.(\[?])", body):
            target, value = m.group(1), m.group(2)
            if value in bound and props.get(target) in ("Int", "Double", "Int?", "Double?"):
                fn, ret = bound[value]
                ln = line_of(node) + body[:m.start()].count("\n")
                report.error(short, ln, f"{target} is {props[target]} but {value} is {ret} (from qemu.{fn}) — "
                                        f"convert it: {props[target].rstrip('?')}({value})")


def main():
    roots = sys.argv[1:] or ["ios/App/Sources"]
    files = []
    for root in roots:
        if os.path.isfile(root):
            files.append(root)
            continue
        for d, _, names in os.walk(root):
            files += [os.path.join(d, n) for n in names if n.endswith(".swift")]
    files.sort()

    idx = Index()
    parsed = []
    report = Report()
    for f in files:
        raw = open(f, "rb").read()
        if os.path.basename(f) == "QemuRuntime.swift":
            idx.runtime_returns = runtime_returns(raw)
        src = parseable(raw)
        tree = PARSER.parse(src)
        parsed.append((f, src, tree))
        # Syntax first: a file that doesn't parse can't be checked further.
        for n in walk(tree.root_node):
            if n.type == "ERROR" or n.is_missing:
                report.error(os.path.relpath(f), line_of(n), "does not parse here")
                break
        for n in tree.root_node.children:
            if n.type == "class_declaration":
                index_decl(src, idx, n)
            elif n.type == "protocol_declaration":
                index_protocol(src, idx, n)
            elif n.type == "function_declaration":
                nm = n.child_by_field_name("name")
                if nm is not None:
                    idx.globals.add(text(src, nm))
    # App protocol extensions add members to every adopter.
    for info in idx.types.values():
        for sup in list(info.supers):
            if sup in idx.types and idx.types[sup].kind == "protocol":
                info.members |= idx.types[sup].members
    finish(idx)

    for f, src, tree in parsed:
        check_file(f, src, tree, idx, report)

    for w in report.warnings:
        print(w)
    for e in report.errors:
        print(e)
    print(f"precheck: {len(files)} files, {len(report.errors)} error(s), {len(report.warnings)} warning(s)")
    sys.exit(1 if report.errors else 0)


if __name__ == "__main__":
    main()
