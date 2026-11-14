// SPDX-License-Identifier: GPL-2.0-or-later
//! A small reader for shell command lines, just enough to find the commands that would run: it splits on `;`, `&&`,
//! `||`, `|`, `&` and newlines, removes quotes, drops comments and heredoc bodies, notes redirections, and pulls out
//! command substitutions (`$( )` and backticks) so they can be read as commands of their own. It does not run or
//! expand anything and it never panics: what it cannot read is simply not reported (the guardrail is advisory).

/// One command: its words (quotes removed) and the files it redirects output into.
#[derive(Debug, Default, Clone, PartialEq)]
pub struct Simple {
    pub words: Vec<String>,
    /// `(append, target)` for `>`, `>>`, `>|` and `&>`.
    pub redirects: Vec<(bool, String)>,
}

#[derive(Debug, Default)]
pub struct Parsed {
    pub simples: Vec<Simple>,
    /// The text inside each command substitution, to be read as a command line of its own.
    pub subs: Vec<String>,
}

#[derive(Clone, Copy, PartialEq)]
enum Pending {
    None,
    Out(bool),
    Ignore,
}

/// The longest command line that is read (the rest is ignored).
const MAX_CHARS: usize = 20_000;

pub fn parse(cmd: &str) -> Parsed {
    let chars: Vec<char> = cmd.chars().take(MAX_CHARS).collect();
    let mut p = Parser {
        chars,
        i: 0,
        out: Parsed::default(),
        simple: Simple::default(),
        word: None,
        pending: Pending::None,
        heredocs: Vec::new(),
    };
    p.run();
    p.out
}

struct Parser {
    chars: Vec<char>,
    i: usize,
    out: Parsed,
    simple: Simple,
    word: Option<String>,
    pending: Pending,
    heredocs: Vec<String>,
}

impl Parser {
    fn peek(&self, k: usize) -> Option<char> {
        self.chars.get(self.i + k).copied()
    }

    fn word_push(&mut self, c: char) {
        self.word.get_or_insert_with(String::new).push(c);
    }

    fn end_word(&mut self) {
        if let Some(w) = self.word.take() {
            match self.pending {
                Pending::Out(append) => self.simple.redirects.push((append, w)),
                Pending::Ignore => {}
                Pending::None => self.simple.words.push(w),
            }
            self.pending = Pending::None;
        }
    }

    fn end_simple(&mut self) {
        self.end_word();
        self.pending = Pending::None;
        let s = std::mem::take(&mut self.simple);
        if !s.words.is_empty() || !s.redirects.is_empty() {
            self.out.simples.push(s);
        }
    }

    fn skip_heredocs(&mut self) {
        let delims = std::mem::take(&mut self.heredocs);
        for delim in delims {
            loop {
                if self.i >= self.chars.len() {
                    return;
                }
                let start = self.i;
                while self.i < self.chars.len() && self.chars[self.i] != '\n' {
                    self.i += 1;
                }
                let line: String = self.chars[start..self.i].iter().collect();
                if self.i < self.chars.len() {
                    self.i += 1; // the newline
                }
                if line.trim() == delim {
                    break;
                }
            }
        }
    }

    /// Reads a `$(`...`)` (the cursor is after `$(`) and returns its inner text.
    fn read_paren_sub(&mut self) -> String {
        let mut depth = 1usize;
        let mut inner = String::new();
        let mut quote: Option<char> = None;
        while let Some(c) = self.peek(0) {
            self.i += 1;
            match quote {
                Some(q) => {
                    if c == q {
                        quote = None;
                    }
                }
                None => match c {
                    '\'' | '"' => quote = Some(c),
                    '(' => depth += 1,
                    ')' => {
                        depth -= 1;
                        if depth == 0 {
                            return inner;
                        }
                    }
                    _ => {}
                },
            }
            inner.push(c);
        }
        inner
    }

    fn read_backtick_sub(&mut self) -> String {
        let mut inner = String::new();
        while let Some(c) = self.peek(0) {
            self.i += 1;
            match c {
                '`' => return inner,
                '\\' => {
                    if let Some(n) = self.peek(0) {
                        self.i += 1;
                        inner.push(n);
                    }
                }
                _ => inner.push(c),
            }
        }
        inner
    }

    fn run(&mut self) {
        while let Some(c) = self.peek(0) {
            match c {
                ' ' | '\t' | '\r' => {
                    self.i += 1;
                    self.end_word();
                }
                '\n' => {
                    self.i += 1;
                    self.end_simple();
                    self.skip_heredocs();
                }
                ';' | '(' | ')' => {
                    self.i += 1;
                    self.end_simple();
                }
                '|' => {
                    self.i += 1;
                    if self.peek(0) == Some('|') || self.peek(0) == Some('&') {
                        self.i += 1;
                    }
                    self.end_simple();
                }
                '&' => {
                    self.i += 1;
                    if self.peek(0) == Some('>') {
                        // &> file: redirects both streams
                        self.i += 1;
                        let append = self.peek(0) == Some('>');
                        if append {
                            self.i += 1;
                        }
                        self.end_word();
                        self.pending = Pending::Out(append);
                    } else {
                        if self.peek(0) == Some('&') {
                            self.i += 1;
                        }
                        self.end_simple();
                    }
                }
                '#' if self.word.is_none() => {
                    while let Some(n) = self.peek(0) {
                        if n == '\n' {
                            break;
                        }
                        self.i += 1;
                    }
                }
                '>' => self.redirect_out(),
                '<' => self.redirect_in(),
                '\\' => {
                    self.i += 1;
                    match self.peek(0) {
                        Some('\n') => self.i += 1, // line continuation
                        Some(n) => {
                            self.i += 1;
                            self.word_push(n);
                        }
                        None => {}
                    }
                }
                '\'' => {
                    self.i += 1;
                    self.word.get_or_insert_with(String::new);
                    while let Some(n) = self.peek(0) {
                        self.i += 1;
                        if n == '\'' {
                            break;
                        }
                        self.word_push(n);
                    }
                }
                '"' => {
                    self.i += 1;
                    self.word.get_or_insert_with(String::new);
                    while let Some(n) = self.peek(0) {
                        self.i += 1;
                        match n {
                            '"' => break,
                            '\\' => {
                                if let Some(e) = self.peek(0) {
                                    self.i += 1;
                                    if !matches!(e, '"' | '\\' | '$' | '`') {
                                        self.word_push('\\');
                                    }
                                    self.word_push(e);
                                }
                            }
                            '$' if self.peek(0) == Some('(') => {
                                self.i += 1;
                                let inner = self.read_paren_sub();
                                self.out.subs.push(inner);
                                self.word_push('$');
                            }
                            '`' => {
                                let inner = self.read_backtick_sub();
                                self.out.subs.push(inner);
                                self.word_push('$');
                            }
                            _ => self.word_push(n),
                        }
                    }
                }
                '$' if self.peek(1) == Some('(') => {
                    self.i += 2;
                    let inner = self.read_paren_sub();
                    self.out.subs.push(inner);
                    self.word_push('$');
                }
                '`' => {
                    self.i += 1;
                    let inner = self.read_backtick_sub();
                    self.out.subs.push(inner);
                    self.word_push('$');
                }
                _ => {
                    self.i += 1;
                    self.word_push(c);
                }
            }
        }
        self.end_simple();
    }

    fn redirect_out(&mut self) {
        // A bare file descriptor number before the operator (2>file) is not a word.
        if let Some(w) = &self.word {
            if !w.is_empty() && w.chars().all(|c| c.is_ascii_digit()) {
                self.word = None;
            }
        }
        self.end_word();
        self.i += 1; // the '>'
        let mut append = false;
        match self.peek(0) {
            Some('>') => {
                append = true;
                self.i += 1;
            }
            Some('|') => {
                self.i += 1;
            }
            Some('&') => {
                // >&2 or >&- : a descriptor, not a file
                self.i += 1;
                while matches!(self.peek(0), Some(c) if c.is_ascii_digit() || c == '-') {
                    self.i += 1;
                }
                return;
            }
            _ => {}
        }
        self.pending = Pending::Out(append);
    }

    fn redirect_in(&mut self) {
        self.end_word();
        self.i += 1; // the '<'
        match self.peek(0) {
            Some('<') => {
                self.i += 1;
                if self.peek(0) == Some('<') {
                    // <<< here-string: its word is data
                    self.i += 1;
                    self.pending = Pending::Ignore;
                    return;
                }
                if self.peek(0) == Some('-') {
                    self.i += 1;
                }
                while matches!(self.peek(0), Some(' ' | '\t')) {
                    self.i += 1;
                }
                let mut delim = String::new();
                while let Some(c) = self.peek(0) {
                    if c.is_whitespace() || matches!(c, ';' | '|' | '&' | '<' | '>' | '(' | ')') {
                        break;
                    }
                    self.i += 1;
                    if !matches!(c, '\'' | '"' | '\\') {
                        delim.push(c);
                    }
                }
                if !delim.is_empty() {
                    self.heredocs.push(delim);
                }
            }
            Some('&') => {
                self.i += 1;
                while matches!(self.peek(0), Some(c) if c.is_ascii_digit() || c == '-') {
                    self.i += 1;
                }
            }
            _ => self.pending = Pending::Ignore,
        }
    }
}
