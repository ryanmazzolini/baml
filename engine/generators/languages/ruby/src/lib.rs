use std::collections::{HashMap, HashSet};

use dir_writer::{FileCollector, GeneratorArgs, IntermediateRepr, LanguageFeatures};
use functions::{render_client, render_runtime};
use generated_types::render_rb_types;
use petgraph::graph::DiGraph;

use crate::{
    functions::render_globals,
    generated_types::{
        render_rb_stream_types_utils, render_rb_type_builder, render_rb_types_utils, ClassRb,
        TypeAliasRb,
    },
};

mod functions;
mod generated_types;
mod ir_to_rb;
mod package;
mod r#type;
mod utils;

/// Collect class/type-alias names referenced by a rendered TypeRb tree.
fn collect_type_refs(ty: &r#type::TypeRb, out: &mut HashSet<String>) {
    use r#type::TypeRb;
    match ty {
        TypeRb::Class { name, .. } | TypeRb::TypeAlias { name, .. } => {
            out.insert(name.clone());
        }
        TypeRb::List(inner, _) => collect_type_refs(inner, out),
        TypeRb::Map(k, v, _) => {
            collect_type_refs(k, out);
            collect_type_refs(v, out);
        }
        TypeRb::Union { variants, .. } => {
            for v in variants {
                collect_type_refs(v, out);
            }
        }
        _ => {}
    }
}

/// Replace references to not-yet-defined classes with `T.anything`.
fn replace_forward_refs(ty: &mut r#type::TypeRb, forward: &HashSet<String>) {
    use r#type::TypeRb;
    match ty {
        TypeRb::Class { name, meta, .. } | TypeRb::TypeAlias { name, meta, .. }
            if forward.contains(name.as_str()) =>
        {
            *ty = TypeRb::Any {
                reason: format!("forward ref to mutually recursive {name}"),
                meta: std::mem::take(meta),
            };
        }
        TypeRb::List(inner, _) => replace_forward_refs(inner, forward),
        TypeRb::Map(k, v, _) => {
            replace_forward_refs(k, forward);
            replace_forward_refs(v, forward);
        }
        TypeRb::Union { variants, .. } => {
            for v in variants {
                replace_forward_refs(v, forward);
            }
        }
        _ => {}
    }
}

/// Result of analyzing a dependency graph for topological ordering and cycles.
struct DepGraphAnalysis {
    /// Position of each name in toposorted emission order.
    positions: HashMap<String, usize>,
    /// For names in multi-node strongly connected components, the full set of cycle members.
    cycle_members: HashMap<String, HashSet<String>>,
}

/// Condense strongly connected components and toposort the resulting DAG.
///
/// Returns emission positions and cycle membership for each node. Used by both
/// `toposort_classes` (for class forward-ref ordering) and `break_alias_cycles`
/// (for type alias mutual recursion).
fn analyze_dep_graph(graph: DiGraph<String, ()>) -> DepGraphAnalysis {
    let condensed = petgraph::algo::condensation(graph, true);
    let sorted_scc = petgraph::algo::toposort(&condensed, None)
        .expect("condensation always produces a DAG");

    let mut positions: HashMap<String, usize> = HashMap::new();
    let mut cycle_members: HashMap<String, HashSet<String>> = HashMap::new();
    let mut i = 0;
    for idx in &sorted_scc {
        let members = &condensed[*idx];
        if members.len() > 1 {
            let member_set: HashSet<String> = members.iter().cloned().collect();
            for name in members {
                cycle_members.insert(name.clone(), member_set.clone());
            }
        }
        for name in members {
            positions.insert(name.clone(), i);
            i += 1;
        }
    }

    DepGraphAnalysis {
        positions,
        cycle_members,
    }
}

/// Build a dependency graph from named items and their type references.
fn build_dep_graph<'a>(
    items: impl Iterator<Item = (&'a str, HashSet<String>)>,
) -> DiGraph<String, ()> {
    let items: Vec<_> = items.collect();
    let mut graph = DiGraph::<String, ()>::new();
    let mut node_map: HashMap<&str, petgraph::graph::NodeIndex> = HashMap::new();

    for &(name, _) in &items {
        let idx = graph.add_node(name.to_string());
        node_map.insert(name, idx);
    }

    for &(name, ref refs) in &items {
        let Some(&dependent) = node_map.get(name) else {
            continue;
        };
        for dep_name in refs {
            if dep_name != name {
                if let Some(&dependency) = node_map.get(dep_name.as_str()) {
                    graph.add_edge(dependency, dependent, ());
                }
            }
        }
    }

    graph
}

/// Sort classes topologically so field-type dependencies are defined first.
///
/// Ruby evaluates class bodies eagerly at `require` time — when `T::Struct` sees
/// `const :field, SomeClass`, it resolves `SomeClass` immediately as a constant.
/// If that class hasn't been defined yet in the file, Ruby raises `NameError`.
/// Other languages don't need this: Python uses string annotations resolved lazily
/// by Pydantic, TypeScript hoists `interface` declarations, and Go resolves all
/// types at package scope.
///
/// For acyclic dependencies (A → B → C), topological sorting alone suffices.
/// For mutual recursion (Tree → Forest → Tree), no ordering works — one class
/// will always reference the other before it exists. We handle this by collapsing
/// strongly connected components into single nodes via `petgraph::algo::condensation`,
/// producing a DAG that can be toposorted. Back-edge references within cycles
/// (classes not yet emitted at point of reference) are replaced with `T.anything`.
fn toposort_classes(classes: Vec<ClassRb<'_>>) -> Vec<ClassRb<'_>> {
    let graph = build_dep_graph(classes.iter().map(|c| {
        let mut refs = HashSet::new();
        for field in &c.fields {
            collect_type_refs(&field.r#type, &mut refs);
        }
        (c.name.as_str(), refs)
    }));

    let analysis = analyze_dep_graph(graph);

    let mut sorted = classes;
    sorted.sort_by_key(|c| analysis.positions.get(&c.name).copied().unwrap_or(usize::MAX));

    // For classes in a cycle, replace references to not-yet-emitted cycle members
    // with T.anything — no valid ordering exists for mutual recursion in Ruby.
    let mut emitted: HashSet<String> = HashSet::new();
    for class in &mut sorted {
        if let Some(scc) = analysis.cycle_members.get(&class.name) {
            let forward: HashSet<String> = scc
                .iter()
                .filter(|n| *n != &class.name && !emitted.contains(*n))
                .cloned()
                .collect();
            if !forward.is_empty() {
                for field in &mut class.fields {
                    replace_forward_refs(&mut field.r#type, &forward);
                }
            }
        }
        emitted.insert(class.name.clone());
    }

    sorted
}

/// Break cycles in mutually recursive type aliases.
///
/// `T.type_alias{ block }` stores its block lazily, but Sorbet eagerly coerces
/// type arguments inside `T.any(...)`, `T::Array[...]`, etc. — so a cycle like
/// `JsonValue → JsonObject → JsonValue` still causes infinite recursion at load
/// time. Self-referential aliases are already handled by `is_defining_alias` in
/// `type.rs`; this function extends that to cross-alias cycles.
fn break_alias_cycles(aliases: &mut [TypeAliasRb<'_>]) {
    let graph = build_dep_graph(aliases.iter().map(|a| {
        let mut refs = HashSet::new();
        collect_type_refs(&a.type_, &mut refs);
        (a.name.as_str(), refs)
    }));

    let analysis = analyze_dep_graph(graph);
    if analysis.cycle_members.is_empty() {
        return;
    }

    // Unlike classes (where only forward refs need replacing), all cross-references
    // within an alias cycle cause infinite recursion because Sorbet resolves them
    // eagerly inside type expressions like T.any(...).
    for alias in aliases.iter_mut() {
        if let Some(scc) = analysis.cycle_members.get(&alias.name) {
            let peers: HashSet<String> = scc
                .iter()
                .filter(|n| *n != &alias.name)
                .cloned()
                .collect();
            if !peers.is_empty() {
                replace_forward_refs(&mut alias.type_, &peers);
            }
        }
    }
}

#[derive(Default)]
pub struct RbLanguageFeatures {
    requires: std::sync::Mutex<std::collections::HashMap<std::path::PathBuf, Vec<String>>>,
    requires_relative: std::sync::Mutex<std::collections::HashMap<std::path::PathBuf, Vec<String>>>,
}

impl RbLanguageFeatures {
    fn add_import(&self, path: &str, import: &str, relative: bool) {
        let mut map = if relative {
            self.requires_relative.lock().unwrap()
        } else {
            self.requires.lock().unwrap()
        };
        map.entry(std::path::Path::new(path).to_path_buf())
            .or_insert_with(Vec::new)
            .push(import.to_string());
    }
}

impl LanguageFeatures for RbLanguageFeatures {
    const CONTENT_PREFIX: &'static str = r#"
# typed: strict
# ----------------------------------------------------------------------------
#
#  Welcome to Baml! To use this generated code, please run the following:
#
#  $ gem install baml
#
# ----------------------------------------------------------------------------

# This file was generated by BAML: please do not edit it. Instead, edit the
# BAML files and re-generate this code using: baml-cli generate
# baml-cli is available with the baml package.
# gem install baml
        "#;

    fn name() -> &'static str {
        "ruby/sorbet"
    }

    fn on_file_created(
        &self,
        _path: &std::path::Path,
        _content: &mut String,
    ) -> anyhow::Result<()> {
        // Do nothing we'll do this in on_file_finished
        self.add_import(_path.to_str().unwrap(), "sorbet-runtime", false);
        self.add_import(_path.to_str().unwrap(), "baml", false);
        Ok(())
    }

    fn on_file_finished(&self, path: &std::path::Path, content: &mut String) -> anyhow::Result<()> {
        *content = {
            let mut new_content = self.content_prefix().to_string();
            if let Some(requires) = self.requires.lock().unwrap().get(path) {
                new_content.push('\n');
                for require in requires {
                    new_content.push_str(&format!("require \"{require}\"\n"));
                }
            }
            if let Some(requires) = self.requires_relative.lock().unwrap().get(path) {
                new_content.push('\n');
                for require in requires {
                    new_content.push_str(&format!("require_relative \"{require}\"\n"));
                }
            }
            new_content.push('\n');
            new_content.push_str("module BamlClient\n");
            for line in content.split("\n") {
                if line.trim().is_empty() {
                    new_content.push('\n');
                } else {
                    new_content.push_str(&format!("  {line}\n"));
                }
            }
            new_content.push_str("\nend\n");
            new_content
        };
        Ok(())
    }

    fn generate_sdk_files(
        &self,
        collector: &mut FileCollector<Self>,
        ir: std::sync::Arc<IntermediateRepr>,
        args: &GeneratorArgs,
    ) -> Result<(), anyhow::Error> {
        let pkg = package::CurrentRenderPackage::new("BamlClient", ir.clone());
        let _file_map = args.file_map_as_json_string()?;

        // collector.add_file("b.rb", render_init(&pkg, &args.default_client_mode)?)?;
        // collector.add_file("inlinedbaml.rb", render_source_files(file_map)?)?;
        collector.add_file("runtime.rb", render_runtime(&pkg)?)?;
        self.add_import("runtime.rb", "globals", true);
        self.add_import("runtime.rb", "type_builder", true);
        // collector.add_file("tracing.rb", render_tracing(&pkg)?)?;
        collector.add_file("globals.rb", render_globals(&pkg)?)?;
        // collector.add_file("config.rb", render_config(&pkg)?)?;
        let functions = ir
            .functions
            .iter()
            .map(|f| ir_to_rb::functions::ir_function_to_rb(f, &pkg))
            .collect::<Vec<_>>();
        collector.add_file("client.rb", render_client(&functions, &pkg)?)?;
        self.add_import("client.rb", "runtime", true);
        self.add_import("client.rb", "types", true);
        self.add_import("client.rb", "stream_types", true);
        // collector.add_file("parser.rb", render_parser(&functions, &pkg)?)?;

        let rb_classes = toposort_classes(
            ir.walk_classes()
                .map(|c| ir_to_rb::classes::ir_class_to_rb(c.item, &pkg))
                .collect(),
        );
        let enums = ir
            .walk_enums()
            .map(|e| ir_to_rb::enums::ir_enum_to_rb(e.item, &pkg))
            .collect::<Vec<_>>();
        let type_aliases = ir.walk_type_aliases().collect::<Vec<_>>();
        let mut rb_type_aliases = type_aliases
            .iter()
            .map(|c| ir_to_rb::type_aliases::ir_type_alias_to_rb(c.item, &pkg))
            .collect::<Vec<_>>();
        rb_type_aliases.sort_by(|a, b| a.name.cmp(&b.name));
        break_alias_cycles(&mut rb_type_aliases);

        // pkg.set("baml_client.type_map");
        // collector.add_file("type_map.rb", render_type_map(&rb_classes, &enums)?)?;

        pkg.set("BamlClient");
        collector.add_file(
            "type_builder.rb",
            render_rb_type_builder(&rb_classes, &enums)?,
        )?;

        pkg.set("BamlClient.Types");
        collector.add_file("types.rb", "module Types\n")?;
        collector.append_to_file("types.rb", &render_rb_types_utils(&pkg)?)?;
        collector.append_to_file("types.rb", &render_rb_types(&enums, &pkg)?)?;
        // Type aliases before classes: T.type_alias{ } captures a lazy block, so aliases
        // can be defined before the types they reference. But classes eagerly resolve
        // constants in `const` declarations, so aliases they depend on must exist first.
        collector.append_to_file("types.rb", &render_rb_types(&rb_type_aliases, &pkg)?)?;
        collector.append_to_file("types.rb", &render_rb_types(&rb_classes, &pkg)?)?;
        collector.append_to_file("types.rb", "\nend\n")?;

        let mut rb_stream_type_aliases = type_aliases
            .iter()
            .map(|c| ir_to_rb::type_aliases::ir_type_alias_to_rb_stream(c.item, &pkg))
            .collect::<Vec<_>>();
        rb_stream_type_aliases.sort_by(|a, b| a.name.cmp(&b.name));
        break_alias_cycles(&mut rb_stream_type_aliases);

        let rb_stream_classes = toposort_classes(
            ir.walk_classes()
                .map(|c| ir_to_rb::classes::ir_class_to_rb_stream(c.item, &pkg))
                .collect(),
        );

        pkg.set("BamlClient.StreamTypes");
        collector.add_file("stream_types.rb", "module StreamTypes\n")?;
        collector.append_to_file("stream_types.rb", &render_rb_stream_types_utils(&pkg)?)?;
        collector.append_to_file(
            "stream_types.rb",
            &render_rb_types(&rb_stream_type_aliases, &pkg)?,
        )?;
        collector.append_to_file("stream_types.rb", &render_rb_types(&rb_stream_classes, &pkg)?)?;
        collector.append_to_file("stream_types.rb", "\nend\n")?;

        Ok(())
    }
}

// DISABLED: Ruby tests are not working yet
// #[cfg(test)]
// mod ruby_tests {
//     use test_harness::{create_code_gen_test_suites, TestLanguageFeatures};

//     impl TestLanguageFeatures for crate::RbLanguageFeatures {
//         fn test_name() -> &'static str {
//             "ruby"
//         }
//     }

//     create_code_gen_test_suites!(crate::RbLanguageFeatures);
// }

#[cfg(test)]
mod tests {
    #[test]
    fn templates_do_not_shadow_common_user_arg_names() {
        // The Ruby client template renders method signatures that include user-defined
        // argument names (as keyword args). Avoid locals like `options`, `result`, `parsed`,
        // or `ctx` inside those methods, since a BAML arg with the same name would be
        // shadowed/overwritten.

        let client = include_str!("./_templates/client.rb.j2");
        assert!(!client.contains("\n        options = @options.merge_options"));
        assert!(client.contains("\n        __options__ = @options.merge_options"));
        assert!(!client.contains("\n        result = options.call_function_sync"));
        assert!(client.contains("\n        __result__ = __options__.call_function_sync"));
        assert!(!client.contains("\n        parsed = result.parsed_using_types"));
        assert!(client.contains("\n        __parsed__ = __result__.parsed_using_types"));
        assert!(!client.contains("\n        ctx, result = options.create_sync_stream"));
        assert!(client.contains("\n        __ctx__, __result__ = __options__.create_sync_stream"));

        // These templates live in the ruby generator template directory as well; keep them safe
        // to avoid future regressions if/when they are wired in.
        let parser = include_str!("./_templates/parser.rb.j2");
        assert!(!parser.contains("\n        result = "));
        assert!(parser.contains("\n        __result__ = "));

        let function_stream = include_str!("./_templates/function.stream.py.j2");
        assert!(!function_stream.contains("\n        options: BamlCallOptions ="));
        assert!(function_stream.contains("\n        __options__: BamlCallOptions ="));
        assert!(!function_stream.contains("\n        collector = "));
        assert!(function_stream.contains("\n        __collector__ = "));
        assert!(!function_stream.contains("\n        collectors = "));
        assert!(function_stream.contains("\n        __collectors__ = "));
        assert!(!function_stream.contains("\n        env = "));
        assert!(function_stream.contains("\n        __env__ = "));
        assert!(!function_stream.contains("\n        raw = "));
        assert!(function_stream.contains("\n        __raw__ = "));
    }

    #[test]
    fn test_name() {
        use std::str::FromStr;

        use dir_writer::LanguageFeatures;

        let gen_type = baml_types::GeneratorOutputType::from_str(crate::RbLanguageFeatures::name())
            .expect("RbLanguageFeatures name should be a valid GeneratorOutputType");
        assert_eq!(gen_type, baml_types::GeneratorOutputType::RubySorbet);
    }
}
