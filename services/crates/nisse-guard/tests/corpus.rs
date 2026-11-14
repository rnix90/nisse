// SPDX-License-Identifier: GPL-2.0-or-later
//! The guardrail classifier against a corpus of tool calls (N-204, design 6.4): deleting or overwriting user data
//! outside snapshots, and outbound actions (sending, posting, pushing, uploading, spending), are guarded; reading,
//! downloading and local work are free. The classifier is advisory in v1: what it cannot read counts as free.

use nisse_guard::{classify, Category, Context, Verdict};
use serde_json::{json, Value};

const CWD: &str = "/home/u/project";
const HOME: &str = "/home/u";
/// Files that exist on the pretend machine (the classifier asks, it never touches the disk in these tests).
const EXISTING: &[&str] = &[
    "/home/u/notes.txt",
    "/home/u/.bashrc",
    "/home/u/project/main.rs",
    "/home/u/project/README.md",
    "/etc/hosts",
    "/tmp/old.log",
];

fn exists(path: &str) -> bool {
    EXISTING.contains(&path)
}

fn cx() -> Context<'static> {
    Context {
        cwd: CWD,
        home: HOME,
        exists: &exists,
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
enum Want {
    Free,
    Guard(Category),
}

use Want::{Free, Guard};

fn bash(cmd: &str) -> (String, Value) {
    ("Bash".into(), json!({ "command": cmd }))
}

fn tool(name: &str, input: Value) -> (String, Value) {
    (name.into(), input)
}

fn corpus() -> Vec<(&'static str, (String, Value), Want)> {
    use Category::{Delete, Outbound, Overwrite, Spend};
    vec![
        // ---- free: reading, local work, downloads
        ("ls", bash("ls -la"), Free),
        ("cat", bash("cat /etc/hosts"), Free),
        ("grep", bash("grep -r foo ."), Free),
        ("git status", bash("git status"), Free),
        ("git log", bash("git log --oneline -5"), Free),
        ("git diff", bash("git diff"), Free),
        ("git pull", bash("git pull"), Free),
        ("git fetch", bash("git fetch --all"), Free),
        ("git commit", bash("git commit -am x"), Free),
        ("git new branch", bash("git checkout -b feat"), Free),
        ("git add", bash("git add -A"), Free),
        ("git stash", bash("git stash"), Free),
        ("git remote -v", bash("git remote -v"), Free),
        ("git push dry run", bash("git push --dry-run origin main"), Free),
        ("cargo build", bash("cargo build --release"), Free),
        ("cargo test", bash("cargo test -q"), Free),
        ("npm install", bash("npm install"), Free),
        ("pip install", bash("pip install requests"), Free),
        ("dnf install", bash("sudo dnf install -y htop"), Free),
        ("curl get", bash("curl https://example.com"), Free),
        ("curl download", bash("curl -O https://example.com/y.tar.gz"), Free),
        ("curl into jq", bash("curl -s https://api.example.com/y | jq ."), Free),
        ("wget download", bash("wget https://example.com/y.iso"), Free),
        ("python", bash("python3 script.py"), Free),
        ("redirect into tmp", bash("echo hi > /tmp/out.txt"), Free),
        ("redirect to a new file", bash("echo hi > brand-new.txt"), Free),
        ("append to a file", bash("echo hi >> /home/u/notes.txt"), Free),
        ("redirect over a project file", bash("echo hi > main.rs"), Free),
        ("rm in tmp", bash("rm /tmp/scratch.txt"), Free),
        ("rm -rf in tmp", bash("rm -rf /tmp/build"), Free),
        ("rm -rf target", bash("rm -rf target"), Free),
        ("rm -rf node_modules", bash("rm -rf node_modules"), Free),
        ("rm -rf nested target", bash("rm -rf ./target/debug"), Free),
        ("rm one file in the project", bash("rm junk.o"), Free),
        ("mkdir", bash("mkdir -p a/b"), Free),
        ("touch", bash("touch x"), Free),
        ("cp to a new file", bash("cp a.txt b.txt"), Free),
        ("mv to a new name", bash("mv a.txt b.txt"), Free),
        ("sed in place", bash("sed -i 's/a/b/' main.rs"), Free),
        (
            "dd to tmp",
            bash("dd if=/dev/zero of=/tmp/test.img bs=1M count=1"),
            Free,
        ),
        ("truncate in tmp", bash("truncate -s 0 /tmp/log"), Free),
        ("find", bash("find . -name '*.o'"), Free),
        ("systemctl status", bash("systemctl status sshd"), Free),
        ("ssh command", bash("ssh nas uptime"), Free),
        ("docker ps", bash("docker ps"), Free),
        ("docker build", bash("docker build -t x ."), Free),
        ("kubectl get", bash("kubectl get pods"), Free),
        ("aws s3 ls", bash("aws s3 ls"), Free),
        ("aws s3 download", bash("aws s3 cp s3://bucket/key ."), Free),
        ("gh pr list", bash("gh pr list"), Free),
        ("gh pr view", bash("gh pr view 3"), Free),
        ("gh api get", bash("gh api repos/o/r"), Free),
        (
            "quoted text is not a command",
            bash("echo \"rm -rf ~ && git push\""),
            Free,
        ),
        ("grep for a command name", bash("grep -r \"git push\" ."), Free),
        (
            "commit message mentions push",
            bash("git commit -m \"git push later\""),
            Free,
        ),
        ("comment", bash("ls # git push"), Free),
        ("echo of a command", bash("echo rm -rf /"), Free),
        (
            "heredoc body",
            bash("cat <<EOF > /tmp/x\nrm -rf ~\ngit push\nEOF"),
            Free,
        ),
        ("empty command", bash(""), Free),
        (
            "read tool",
            tool("Read", json!({ "file_path": "/home/u/notes.txt" })),
            Free,
        ),
        ("glob", tool("Glob", json!({ "pattern": "**/*.rs" })), Free),
        ("grep tool", tool("Grep", json!({ "pattern": "x" })), Free),
        (
            "web fetch",
            tool("WebFetch", json!({ "url": "https://example.com" })),
            Free,
        ),
        ("web search", tool("WebSearch", json!({ "query": "x" })), Free),
        (
            "edit",
            tool(
                "Edit",
                json!({ "file_path": "/home/u/notes.txt", "old_string": "a", "new_string": "b" }),
            ),
            Free,
        ),
        (
            "write a new file",
            tool("Write", json!({ "file_path": "/home/u/new.txt", "content": "x" })),
            Free,
        ),
        (
            "write over a project file",
            tool(
                "Write",
                json!({ "file_path": "/home/u/project/main.rs", "content": "x" }),
            ),
            Free,
        ),
        (
            "write over a relative project file",
            tool("Write", json!({ "file_path": "README.md", "content": "x" })),
            Free,
        ),
        (
            "write over a tmp file",
            tool("Write", json!({ "file_path": "/tmp/old.log", "content": "x" })),
            Free,
        ),
        ("a tool nobody knows", tool("TodoWrite", json!({ "todos": [] })), Free),
        (
            "gcloud config set is local",
            bash("gcloud config set project demo"),
            Free,
        ),
        (
            "a remote-desktop tool is not outbound",
            tool("mcp__claw-box__act", json!({})),
            Free,
        ),
        (
            "mcp search",
            tool("mcp__claude_ai_Gmail__search_threads", json!({ "query": "x" })),
            Free,
        ),
        (
            "mcp get",
            tool("mcp__claude_ai_Gmail__get_message", json!({ "id": "1" })),
            Free,
        ),
        (
            "mcp list",
            tool("mcp__claude_ai_Google_Calendar__list_events", json!({})),
            Free,
        ),
        (
            "mcp read file",
            tool("mcp__claude_ai_Google_Drive__read_file_content", json!({})),
            Free,
        ),
        (
            "mcp download",
            tool("mcp__claude_ai_Google_Drive__download_file_content", json!({})),
            Free,
        ),
        ("no command at all", ("Bash".into(), json!({})), Free),
        (
            "a command that is not a string",
            ("Bash".into(), json!({ "command": 42 })),
            Free,
        ),
        // ---- guarded: deleting
        ("rm -rf home dir", bash("rm -rf ~/Documents"), Guard(Delete)),
        ("rm -rf absolute", bash("rm -rf /home/u/project/src"), Guard(Delete)),
        ("rm -r project dir", bash("rm -r build_notes"), Guard(Delete)),
        (
            "rm -f outside the project",
            bash("rm -f /home/u/notes.txt"),
            Guard(Delete),
        ),
        (
            "rm one file outside the project",
            bash("rm /home/u/notes.txt"),
            Guard(Delete),
        ),
        ("rm -rf star", bash("rm -rf *"), Guard(Delete)),
        ("sudo rm -rf", bash("sudo rm -rf /var/lib/foo"), Guard(Delete)),
        ("rm after a cd", bash("cd /tmp && rm -rf /home/u/x"), Guard(Delete)),
        ("rm in bash -c", bash("bash -c \"rm -rf ~/x\""), Guard(Delete)),
        ("rm after a semicolon", bash("echo x; rm -rf ~/y"), Guard(Delete)),
        (
            "rm in a command substitution",
            bash("echo $(rm -rf ~/z)"),
            Guard(Delete),
        ),
        ("xargs rm", bash("ls | xargs rm -rf"), Guard(Delete)),
        ("find -delete", bash("find / -name x -delete"), Guard(Delete)),
        ("find -exec rm", bash("find . -type f -exec rm {} +"), Guard(Delete)),
        ("shred", bash("shred -u secrets.txt"), Guard(Delete)),
        ("git clean", bash("git clean -fdx"), Guard(Delete)),
        ("git reset --hard", bash("git reset --hard HEAD~3"), Guard(Delete)),
        ("git checkout dot", bash("git checkout -- ."), Guard(Delete)),
        ("git restore dot", bash("git restore ."), Guard(Delete)),
        (
            "rsync --delete",
            bash("rsync -a --delete src/ /home/u/backup/"),
            Guard(Delete),
        ),
        ("mkfs", bash("mkfs.ext4 /dev/sdb1"), Guard(Delete)),
        ("wipefs", bash("wipefs -a /dev/sda"), Guard(Delete)),
        ("dd to a disk", bash("dd if=x.iso of=/dev/sdb"), Guard(Delete)),
        (
            "truncate a real file",
            bash("truncate -s 0 /home/u/notes.txt"),
            Guard(Delete),
        ),
        // ---- guarded: overwriting
        (
            "redirect over a home file",
            bash("echo x > /home/u/notes.txt"),
            Guard(Overwrite),
        ),
        (
            "redirect over a dotfile",
            bash("cat a > /home/u/.bashrc"),
            Guard(Overwrite),
        ),
        (
            "mv onto an existing file",
            bash("mv new.txt /home/u/notes.txt"),
            Guard(Overwrite),
        ),
        (
            "cp onto an existing file",
            bash("cp a /home/u/notes.txt"),
            Guard(Overwrite),
        ),
        (
            "tee onto an existing file",
            bash("echo x | tee /home/u/notes.txt"),
            Guard(Overwrite),
        ),
        (
            "write over a home file",
            tool("Write", json!({ "file_path": "/home/u/notes.txt", "content": "x" })),
            Guard(Overwrite),
        ),
        (
            "write over a system file",
            tool("Write", json!({ "file_path": "/etc/hosts", "content": "x" })),
            Guard(Overwrite),
        ),
        // ---- guarded: outbound
        ("git push", bash("git push"), Guard(Outbound)),
        ("git push force", bash("git push origin main --force"), Guard(Outbound)),
        ("git push -u", bash("git push -u origin feat"), Guard(Outbound)),
        ("gh pr create", bash("gh pr create --title x"), Guard(Outbound)),
        ("gh pr merge", bash("gh pr merge 3"), Guard(Outbound)),
        ("gh issue comment", bash("gh issue comment 3 -b hi"), Guard(Outbound)),
        ("gh release create", bash("gh release create v1"), Guard(Outbound)),
        ("gh repo delete", bash("gh repo delete o/r --yes"), Guard(Outbound)),
        ("gh api post", bash("gh api -X POST repos/o/r/issues"), Guard(Outbound)),
        (
            "gh api with fields",
            bash("gh api repos/o/r/issues -f title=x"),
            Guard(Outbound),
        ),
        (
            "curl post",
            bash("curl -X POST https://api.example.com/x -d '{}'"),
            Guard(Outbound),
        ),
        ("curl -d", bash("curl -d a=b https://example.com"), Guard(Outbound)),
        (
            "curl data-binary",
            bash("curl --data-binary @f https://example.com"),
            Guard(Outbound),
        ),
        (
            "curl form",
            bash("curl -F file=@a https://example.com"),
            Guard(Outbound),
        ),
        ("curl -T", bash("curl -T file https://example.com/up"), Guard(Outbound)),
        (
            "curl upload-file",
            bash("curl --upload-file f ftp://example.com"),
            Guard(Outbound),
        ),
        (
            "curl delete",
            bash("curl -X DELETE https://example.com/y"),
            Guard(Outbound),
        ),
        ("curl put", bash("curl -X PUT https://example.com/y"), Guard(Outbound)),
        (
            "curl json",
            bash("curl --json '{}' https://example.com"),
            Guard(Outbound),
        ),
        (
            "wget post",
            bash("wget --post-data=a=b https://example.com"),
            Guard(Outbound),
        ),
        ("scp up", bash("scp file user@host:/path"), Guard(Outbound)),
        ("rsync up", bash("rsync -av dir/ host:/backup/"), Guard(Outbound)),
        ("mail", bash("mail -s hi a@example.com"), Guard(Outbound)),
        ("sendmail", bash("sendmail a@example.com"), Guard(Outbound)),
        ("aws s3 upload", bash("aws s3 cp f s3://bucket/key"), Guard(Outbound)),
        ("aws s3 sync up", bash("aws s3 sync . s3://bucket"), Guard(Outbound)),
        (
            "aws terminate",
            bash("aws ec2 terminate-instances --instance-ids i-1"),
            Guard(Outbound),
        ),
        ("kubectl apply", bash("kubectl apply -f x.yaml"), Guard(Outbound)),
        ("kubectl delete", bash("kubectl delete pod p"), Guard(Outbound)),
        ("docker push", bash("docker push img:1"), Guard(Outbound)),
        ("npm publish", bash("npm publish"), Guard(Outbound)),
        ("cargo publish", bash("cargo publish"), Guard(Outbound)),
        ("twine upload", bash("twine upload dist/*"), Guard(Outbound)),
        (
            "terraform apply",
            bash("terraform apply -auto-approve"),
            Guard(Outbound),
        ),
        ("helm upgrade", bash("helm upgrade r c"), Guard(Outbound)),
        (
            "gcloud delete",
            bash("gcloud compute instances delete vm"),
            Guard(Outbound),
        ),
        ("push after a cd", bash("cd x && git push"), Guard(Outbound)),
        (
            "push in bash -c",
            bash("bash -c 'git push origin main'"),
            Guard(Outbound),
        ),
        (
            "post in a substitution",
            bash("echo $(curl -X POST https://example.com)"),
            Guard(Outbound),
        ),
        ("push under timeout", bash("timeout 5 git push"), Guard(Outbound)),
        ("push under env", bash("env FOO=1 git push"), Guard(Outbound)),
        (
            "push in the background",
            bash("nohup curl -d x https://example.com &"),
            Guard(Outbound),
        ),
        ("push after a pipe", bash("echo y | git push"), Guard(Outbound)),
        (
            "mcp send",
            tool("mcp__claude_ai_Gmail__send_message", json!({})),
            Guard(Outbound),
        ),
        (
            "mcp trash",
            tool("mcp__claude_ai_Gmail__trash_thread", json!({})),
            Guard(Outbound),
        ),
        (
            "mcp share",
            tool("mcp__claude_ai_Google_Drive__share_file", json!({})),
            Guard(Outbound),
        ),
        (
            "mcp create event",
            tool("mcp__claude_ai_Google_Calendar__create_event", json!({})),
            Guard(Outbound),
        ),
        (
            "mcp create deployment",
            tool("mcp__claude_ai_Vercel__create_deployment", json!({})),
            Guard(Outbound),
        ),
        // ---- guarded: spending
        (
            "mcp purchase",
            tool("mcp__shop__purchase_item", json!({})),
            Guard(Spend),
        ),
        ("mcp checkout", tool("mcp__shop__checkout", json!({})), Guard(Spend)),
        (
            "mcp place order",
            tool("mcp__shop__place_order", json!({})),
            Guard(Spend),
        ),
        (
            "mcp buy domain",
            tool("mcp__claude_ai_Vercel__buy_domain", json!({})),
            Guard(Spend),
        ),
    ]
}

#[test]
fn the_corpus_is_big_enough() {
    assert!(corpus().len() >= 50, "N-204 asks for 50 or more commands");
}

#[test]
fn every_call_in_the_corpus_gets_its_expected_class() {
    let mut wrong = Vec::new();
    for (label, (name, input), want) in corpus() {
        let got = match classify(&name, &input, &cx()) {
            Verdict::Free => Free,
            Verdict::Guarded { category, .. } => Guard(category),
        };
        if got != want {
            wrong.push(format!("{label}: {name} {input} -> {got:?}, wanted {want:?}"));
        }
    }
    assert!(wrong.is_empty(), "{} wrong:\n{}", wrong.len(), wrong.join("\n"));
}

#[test]
fn a_guarded_call_says_why_in_plain_words() {
    let (name, input) = bash("git push origin main");
    match classify(&name, &input, &cx()) {
        Verdict::Guarded { reason, .. } => {
            assert!(reason.to_lowercase().contains("push"), "{reason}");
            assert!(reason.is_ascii());
        }
        v => panic!("{v:?}"),
    }
}

#[test]
fn the_classifier_never_panics_on_odd_input() {
    let long = "a ".repeat(5000);
    let nested = "$(".repeat(300);
    let odd = [
        "",
        "'",
        "\"",
        "`",
        "$(",
        "))))",
        "&&&&",
        ";;;;",
        "<<",
        "<<EOF",
        "> ",
        "rm",
        "rm -",
        "git",
        "curl -X",
        "bash -c",
        "bash -c '",
        "\u{1F600} rm -rf ~",
        "\0",
        long.as_str(),
        nested.as_str(),
    ];
    for cmd in odd {
        let _ = classify("Bash", &json!({ "command": cmd }), &cx());
    }
    for input in [json!(null), json!([]), json!("x"), json!({ "file_path": 5 })] {
        for name in ["Bash", "Write", "mcp__a__b", ""] {
            let _ = classify(name, &input, &cx());
        }
    }
}
