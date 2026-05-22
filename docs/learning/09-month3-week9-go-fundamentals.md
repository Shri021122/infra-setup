# Month 3, Week 9 — Go fundamentals (for K8s)

> The week you learn enough Go to write Kubernetes controllers. Not
> general Go expertise — specifically the subset Kubernetes uses.

## Goal for the week

By Saturday, you can:
- Read any K8s controller code without confusion
- Write idiomatic Go: structs, interfaces, methods, error handling
- Use goroutines + channels for concurrent patterns
- Understand context.Context, the workqueue pattern, informers
- Build 3 small CLI tools that solve real K8s problems

## Time breakdown

- Reading: ~3 hours
- Coding: ~10 hours
- Buffer: ~2 hours

---

## Part 1 — What Go is and why K8s chose it

Go's design pillars (read this once, internalize):

1. **Compilation to single static binary** — no JVM, no runtime, no deps.
   The Kubernetes binary is literally one ~100MB file.
2. **Native concurrency** — goroutines + channels. K8s has THOUSANDS of
   goroutines in a single apiserver.
3. **Simplicity over expressiveness** — 25 keywords total. Easy to read other
   people's code. (Compare to C++.)
4. **Strong stdlib** — `net/http`, `encoding/json` are batteries-included.
5. **Static typing + interfaces** — like Java, but interfaces are implicit
   (duck-typed at compile time).

What Go is NOT good for: data science, machine learning, scripting glue (use
Python/Bash). For systems programming, network services, CLI tools — it's
near-perfect.

---

## Part 2 — Theory: the Go subset you need

### 2.1 Basic syntax

```go
package main

import (
    "fmt"
    "os"
)

func main() {
    name := "world"
    if len(os.Args) > 1 {
        name = os.Args[1]
    }
    fmt.Printf("Hello, %s\n", name)
}
```

`:=` declares + initializes. `var name string = "..."` is the long form.

### 2.2 Structs and methods

```go
type Pod struct {
    Name      string
    Namespace string
    Ready     bool
}

func (p Pod) FullName() string {
    return p.Namespace + "/" + p.Name
}

func (p *Pod) MarkReady() {       // pointer receiver = mutates
    p.Ready = true
}
```

Pointer receivers when mutating; value receivers when not. K8s code uses
pointers ~95% of the time (objects are large).

### 2.3 Interfaces

```go
type Stringer interface {
    String() string
}

func Print(s Stringer) {
    fmt.Println(s.String())
}
```

Anything with a `String() string` method satisfies `Stringer` automatically.
No `implements` keyword.

K8s relies heavily on this. `runtime.Object` is an interface; every K8s
resource type satisfies it without declaring so.

### 2.4 Errors are values

```go
func ReadFile(name string) (string, error) {
    data, err := os.ReadFile(name)
    if err != nil {
        return "", fmt.Errorf("read %s: %w", name, err)
    }
    return string(data), nil
}

func main() {
    content, err := ReadFile("/etc/hosts")
    if err != nil {
        fmt.Println("oops:", err)
        os.Exit(1)
    }
    fmt.Println(content)
}
```

There's no try/catch. Every function that can fail returns `(result, error)`.
The caller MUST check. `%w` in `fmt.Errorf` wraps the original error so
`errors.Is`/`errors.As` work upstream.

### 2.5 Goroutines + channels

```go
func main() {
    ch := make(chan int)
    go func() {
        for i := 0; i < 5; i++ {
            ch <- i
        }
        close(ch)
    }()

    for n := range ch {
        fmt.Println("got", n)
    }
}
```

`go func() { ... }()` launches a goroutine. Channels are how goroutines
communicate. `close()` signals "no more values."

**Race conditions are still possible.** Use `sync.Mutex` to protect shared state, or
better, structure your code so only one goroutine owns a piece of state.

### 2.6 context.Context

K8s code is full of `ctx context.Context`. It's the cancellation mechanism:

```go
func DoWork(ctx context.Context) error {
    for {
        select {
        case <-ctx.Done():
            return ctx.Err()  // cancelled
        case <-time.After(time.Second):
            // do one unit of work
        }
    }
}

// Caller:
ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
defer cancel()
DoWork(ctx)
```

Pass ctx as the FIRST parameter to any function that does I/O or might block.
This is the Go convention.

### 2.7 Slices, maps, and pointers

```go
nums := []int{1, 2, 3}
nums = append(nums, 4)              // slices are growable arrays

m := map[string]int{"a": 1, "b": 2}
m["c"] = 3
val, ok := m["a"]                   // ok=true if key exists

p := &Pod{Name: "x"}                // pointer
fmt.Println(p.Name)                  // implicit deref
```

### 2.8 Goimports + gofmt

Go has one canonical format. Run `gofmt -w .` or `goimports -w .` after
every edit. Your editor's Go plugin does this on save — turn that on.

### 2.9 Modules

```bash
go mod init github.com/yourname/yourtool
go get k8s.io/client-go@latest
go mod tidy
go build .
```

`go.mod` is the manifest. `go.sum` is the lockfile.

### 2.10 Testing

```go
// pod_test.go
package main

import "testing"

func TestFullName(t *testing.T) {
    p := Pod{Namespace: "default", Name: "nginx"}
    got := p.FullName()
    want := "default/nginx"
    if got != want {
        t.Errorf("got %q, want %q", got, want)
    }
}
```

`go test ./...` runs all tests. K8s codebase has hundreds of thousands of
tests; you'll write tons.

---

## Part 3 — Hands-on: 3 CLI tools

Each tool should be ~50-150 lines. Don't over-engineer; write idiomatic
Go and stop.

### Tool 1 — Pod summarizer (~3 hours)

Reads from kubeconfig, lists pods in a namespace, prints a summary table.

```bash
$ podstat default
NAME            STATUS   AGE      RESTARTS
nginx-abc       Running  4d2h     0
postgres-xyz    Running  1d4h     2
```

Steps:
1. `go mod init github.com/<you>/podstat`
2. `go get k8s.io/client-go@latest k8s.io/api@latest k8s.io/apimachinery@latest`
3. Use `clientcmd.BuildConfigFromFlags("", kubeconfig)` to load kubeconfig
4. Create clientset; list pods; iterate and print

Reference:
- <https://github.com/kubernetes/client-go/tree/master/examples>

Time-box: 3 hours. If you're not done, ship what you have and continue
Sunday.

### Tool 2 — Namespace cleaner (~3 hours)

Deletes namespaces matching a name pattern that have been "Active" for
longer than N days.

```bash
$ nscleaner --pattern "test-*" --older-than 7d --dry-run
Would delete: test-jane-123 (age: 14d)
Would delete: test-bob-456 (age: 9d)
```

Skills: regex matching, time math, dry-run pattern (a flag), confirmation
prompts.

### Tool 3 — Image scraper (~3 hours)

Lists every unique container image used in a cluster, with the count of
pods using each.

```bash
$ imgscrape
COUNT  IMAGE
142    quay.io/cilium/cilium:v1.18.3
22     grafana/grafana:11.4.0
14     nginx:1.27
...
```

Skills: maps as counters, sorting by value, multi-namespace listing.

---

## Part 4 — Reading exercises

Read these K8s codebases for ~30 min each. Don't memorize; recognize patterns.

1. **kubectl source** — `kubernetes/kubernetes/staging/src/k8s.io/kubectl/`. Pick `get.go` for `kubectl get`.
2. **client-go informers** — `kubernetes/client-go/informers/core/v1/pod.go`. Get the gist of the watch+cache pattern.
3. **A simple operator** — `kubernetes-sigs/sample-controller`. The canonical "how does a controller work" reference.

Note your questions in a doc. Bring them Saturday.

---

## Part 5 — Saturday review checkpoint

1. **`func (p *Pod) ...` vs `func (p Pod) ...` — when do you use each?**
2. **A function panics. How is that different from returning an error?
   When would you panic on purpose?**
3. **You launch 1000 goroutines that all need a shared counter. What goes
   wrong if you just `i++` on a global? How do you fix it?** (Mutex,
   atomic, or "send to channel.")
4. **`context.Context` — what problem does it solve, and what's a real-world
   K8s scenario where forgetting to pass ctx leaks resources?**
5. **Demo your 3 CLI tools.** I'll ask what each does and read your code
   for one of them.

Bring: the 3 CLI tools in a GitHub repo, your notes on the K8s codebase reading.

---

## Resources

- ["A Tour of Go"](https://go.dev/tour/) — free, ~6 hours, do all of it
- ["Effective Go"](https://go.dev/doc/effective_go) — the canonical style guide
- ["Practical Go Lessons" (free book)](https://www.practical-go-lessons.com/)
- [client-go examples](https://github.com/kubernetes/client-go/tree/master/examples)
- [Go playground](https://go.dev/play/) — for quick experiments

---

## What's next: Week 10 — Kubebuilder + first operator scaffold

You have Go fundamentals. Next week you build a real Kubernetes operator
using Kubebuilder. We pick a small but useful operator: something that
automates a real chore in dealing.
