# 第 6 部分：变量

我刚刚给编译器加上了全局变量，结果和我预想的一样，工作量非常大。
而且在这个过程中，编译器里几乎每一个文件都被修改了。
所以，这一部分会比较长。

## 我们希望变量具备什么能力？

我们希望能够：

 + 声明变量
 + 通过变量取得存储的值
 + 给变量赋值

下面这个 `input02` 会成为我们的测试程序：

```
int fred;
int jim;
fred= 5;
jim= 12;
print fred + jim;
```

最显然的变化是：现在语法里出现了变量声明、赋值语句，
以及表达式中的变量名。
不过在讲这些之前，我们先看看变量是如何实现的。

## 符号表（Symbol Table）

每个编译器最终都需要一张
[symbol table](https://en.wikipedia.org/wiki/Symbol_table)。
以后我们会在里面存的不只是全局变量，
不过现在先看看表项的结构是什么样（定义于 `defs.h`）：

```c
// Symbol table structure
struct symtable {
  char *name;                   // Name of a symbol
};
```

在 `data.h` 中，我们有一个符号数组：

```c
#define NSYMBOLS        1024            // Number of symbol table entries
extern_ struct symtable Gsym[NSYMBOLS]; // Global symbol table
static int Globs = 0;                   // Position of next free global symbol slot
```

`Globs` 实际上定义在 `sym.c` 中，
也就是负责管理符号表的那个文件。
其中有下面这些管理函数：

  + `int findglob(char *s)`：判断符号 `s` 是否存在于全局符号表中。
     如果找到，返回槽位编号；找不到则返回 `-1`。
  + `static int newglob(void)`：获取一个新的全局符号槽位；
     如果已经没有空位，就直接报错退出。
  + `int addglob(char *name)`：向符号表中加入一个全局符号，
     并返回它在符号表中的槽位编号。

这些代码都比较直接，所以这里就不展开贴了。
有了这些函数，我们就能查找符号，并把新符号加入符号表。

## 扫描与新 token

如果你看一下示例输入文件，就会发现我们需要一些新 token：

  + `'int'`，记作 `T_INT`
  + `'='`，记作 `T_EQUALS`
  + 标识符名称，记作 `T_IDENT`

在 `scan()` 中加入对 `=` 的扫描很简单：

```c
  case '=':
    t->token = T_EQUALS; break;
```

在 `keyword()` 中加入 `int` 关键字：

```c
  case 'i':
    if (!strcmp(s, "int"))
      return (T_INT);
    break;
```

至于标识符，我们已经在用 `scanident()` 把单词读入 `Text` 变量。
现在与其在一个单词不是关键字时直接报错，
不如返回一个 `T_IDENT` token：

```c
   if (isalpha(c) || '_' == c) {
      // Read in a keyword or identifier
      scanident(c, Text, TEXTLEN);

      // If it's a recognised keyword, return that token
      if (tokentype = keyword(Text)) {
        t->token = tokentype;
        break;
      }
      // Not a recognised keyword, so it must be an identifier
      t->token = T_IDENT;
      break;
    }
```

## 新语法

现在差不多可以来看输入语言语法的变化了。
和之前一样，我仍然用 BNF 来定义它：

```
 statements: statement
      |      statement statements
      ;

 statement: 'print' expression ';'
      |     'int'   identifier ';'
      |     identifier '=' expression ';'
      ;

 identifier: T_IDENT
      ;
```

一个标识符会以 `T_IDENT` token 的形式返回，
而 `print` 语句我们已经有相应的解析代码了。
不过，由于现在已经有三类语句，
为每一类都写一个独立函数就更合理了。
`stmt.c` 中顶层的 `statements()` 现在长这样：

```c
// Parse one or more statements
void statements(void) {

  while (1) {
    switch (Token.token) {
    case T_PRINT:
      print_statement();
      break;
    case T_INT:
      var_declaration();
      break;
    case T_IDENT:
      assignment_statement();
      break;
    case T_EOF:
      return;
    default:
      fatald("Syntax error, token", Token.token);
    }
  }
}
```

我把原先 `print` 语句的代码挪进了 `print_statement()`，
你可以自己去翻那部分实现。

## 变量声明

下面来看变量声明。
它放在一个新文件 `decl.c` 中，
因为未来我们还会增加很多其他类型的声明。

```c
// Parse the declaration of a variable
void var_declaration(void) {

  // Ensure we have an 'int' token followed by an identifier
  // and a semicolon. Text now has the identifier's name.
  // Add it as a known identifier
  match(T_INT, "int");
  ident();
  addglob(Text);
  genglobsym(Text);
  semi();
}
```

这里的 `ident()` 和 `semi()` 都只是 `match()` 的包装：

```c
void semi(void)  { match(T_SEMI, ";"); }
void ident(void) { match(T_IDENT, "identifier"); }
```

回到 `var_declaration()`，
一旦我们把标识符读进 `Text` 缓冲区，
就可以通过 `addglob(Text)` 把它加入全局符号表。
目前那里的代码允许一个变量被重复声明多次。

## 赋值语句

下面是 `stmt.c` 中 `assignment_statement()` 的代码：

```c
void assignment_statement(void) {
  struct ASTnode *left, *right, *tree;
  int id;

  // Ensure we have an identifier
  ident();

  // Check it's been defined then make a leaf node for it
  if ((id = findglob(Text)) == -1) {
    fatals("Undeclared variable", Text);
  }
  right = mkastleaf(A_LVIDENT, id);

  // Ensure we have an equals sign
  match(T_EQUALS, "=");

  // Parse the following expression
  left = binexpr(0);

  // Make an assignment AST tree
  tree = mkastnode(A_ASSIGN, left, right, 0);

  // Generate the assembly code for the assignment
  genAST(tree, -1);
  genfreeregs();

  // Match the following semicolon
  semi();
}
```

这里出现了两个新的 AST 节点类型。
`A_ASSIGN` 会把左孩子中的表达式结果赋给右孩子。
而右孩子则会是一个 `A_LVIDENT` 节点。

为什么我把它叫做 *A_LVIDENT*？
因为它表示的是一个 *lvalue* 标识符。
那什么是
[lvalue](https://en.wikipedia.org/wiki/Value_(computer_science)#lrvalue)？

lvalue 是和某个具体存储位置绑定在一起的值。
在这里，这个位置就是保存变量值的那块内存地址。
比如当我们写：

```
   area = width * height;
```

我们就是把右边的结果（也就是 *rvalue*）
赋给左边那个变量（也就是 *lvalue*）。
`rvalue` 并不绑定到某个固定位置上。
在这里，表达式结果大概只是暂时待在某个寄存器里。

还要注意一点：虽然赋值语句的语法是

```
  identifier '=' expression ';'
```

但我们在 AST 中会把表达式作为 `A_ASSIGN` 的左子树，
把 `A_LVIDENT` 的细节保存在右子树里。
为什么？因为我们必须先计算表达式，
然后才能把结果存进变量中。

## AST 结构的变化

现在，我们既要在 `A_INTLIT` AST 节点里保存整数字面量值，
又要在 `A_IDENT` AST 节点里保存符号信息。
因此我在 AST 结构里加入了一个 *union*（位于 `defs.h`）：

```c
// Abstract Syntax Tree structure
struct ASTnode {
  int op;                       // "Operation" to be performed on this tree
  struct ASTnode *left;         // Left and right child trees
  struct ASTnode *right;
  union {
    int intvalue;               // For A_INTLIT, the integer value
    int id;                     // For A_IDENT, the symbol slot number
  } v;
};
```

## 生成赋值代码

下面来看 `gen.c` 中 `genAST()` 的变化：

```c
int genAST(struct ASTnode *n, int reg) {
  int leftreg, rightreg;

  // Get the left and right sub-tree values
  if (n->left)
    leftreg = genAST(n->left, -1);
  if (n->right)
    rightreg = genAST(n->right, leftreg);

  switch (n->op) {
  ...
    case A_INTLIT:
    return (cgloadint(n->v.intvalue));
  case A_IDENT:
    return (cgloadglob(Gsym[n->v.id].name));
  case A_LVIDENT:
    return (cgstorglob(reg, Gsym[n->v.id].name));
  case A_ASSIGN:
    // The work has already been done, return the result
    return (rightreg);
  default:
    fatald("Unknown AST operator", n->op);
  }

```

注意，我们会先求值左边的 AST 子树，
并得到一个保存左子树值的寄存器编号。
然后再把这个寄存器编号传给右子树。
这样做是为了处理 `A_LVIDENT` 节点，
让 `cg.c` 中的 `cgstorglob()` 知道：
赋值表达式右值的结果此刻在哪个寄存器里。

看看下面这棵 AST：

```
           A_ASSIGN
          /        \
     A_INTLIT   A_LVIDENT
        (3)        (5)
```

我们首先调用 `leftreg = genAST(n->left, -1);`
来求值 `A_INTLIT` 节点。
这会执行 `return (cgloadint(n->v.intvalue));`，
也就是把数值 3 装进某个寄存器，并返回该寄存器编号。

随后，我们调用 `rightreg = genAST(n->right, leftreg);`
来求值 `A_LVIDENT` 节点。
这会执行
`return (cgstorglob(reg, Gsym[n->v.id].name));`，
也就是把这个寄存器里的值存进 `Gsym[5]` 对应名称的变量中。

然后我们才进入 `A_ASSIGN` 这个分支。
但实际上活都已经干完了。
右值依然待在一个寄存器里，所以我们就把它原样返回。
以后我们还可以支持这样的表达式：

```
  a= b= c = 0;
```

那时赋值就不只是语句，也会是表达式。

## 生成 x86-64 代码

你应该已经注意到，
我把原来的 `cgload()` 函数改名成了 `cgloadint()`。
这个名字更明确一些。
现在我们有了一个专门从全局变量中加载值的函数（在 `cg.c` 中）：

```c
int cgloadglob(char *identifier) {
  // Get a new register
  int r = alloc_register();

  // Print out the code to initialise it
  fprintf(Outfile, "\tmovq\t%s(\%%rip), %s\n", identifier, reglist[r]);
  return (r);
}
```

同样地，我们还需要一个把寄存器内容保存进变量的函数：

```c
// Store a register's value into a variable
int cgstorglob(int r, char *identifier) {
  fprintf(Outfile, "\tmovq\t%s, %s(\%%rip)\n", reglist[r], identifier);
  return (r);
}
```

我们还需要一个函数，用来创建新的全局整型变量：

```c
// Generate a global symbol
void cgglobsym(char *sym) {
  fprintf(Outfile, "\t.comm\t%s,8,8\n", sym);
}
```

当然，我们不能让解析器直接去调用这些代码。
因此在通用代码生成器 `gen.c` 中，
还需要一个对外接口函数：

```c
void genglobsym(char *s) { cgglobsym(s); }
```

## 表达式中的变量

现在我们已经能给变量赋值了。
但怎样才能在表达式里取出变量的值呢？
其实我们早就有一个 `primary()` 函数来处理整数字面量；
现在只需要改造它，让它也能加载变量值：

```c
// Parse a primary factor and return an
// AST node representing it.
static struct ASTnode *primary(void) {
  struct ASTnode *n;
  int id;

  switch (Token.token) {
  case T_INTLIT:
    // For an INTLIT token, make a leaf AST node for it.
    n = mkastleaf(A_INTLIT, Token.intvalue);
    break;

  case T_IDENT:
    // Check that this identifier exists
    id = findglob(Text);
    if (id == -1)
      fatals("Unknown variable", Text);

    // Make a leaf AST node for it
    n = mkastleaf(A_IDENT, id);
    break;

  default:
    fatald("Syntax error, token", Token.token);
  }

  // Scan in the next token and return the leaf node
  scan(&Token);
  return (n);
}
```

注意在 `T_IDENT` 分支里有语法检查：
我们会先确认变量已经声明，才允许继续使用它。

还要注意，负责*读取*变量值的 AST 叶子节点是 `A_IDENT`，
而负责把值写入变量的叶子节点是 `A_LVIDENT`。
这正是 *rvalue* 和 *lvalue* 的区别。

## 试一试

我想，变量声明相关的内容差不多就是这些了，
下面就用 `input02` 来试试看：

```
int fred;
int jim;
fred= 5;
jim= 12;
print fred + jim;
```

执行 `make test` 即可：

```
$ make test
cc -o comp1 -g cg.c decl.c expr.c gen.c main.c misc.c scan.c
               stmt.c sym.c tree.c
...
./comp1 input02
cc -o out out.s
./out
17
```

如你所见，我们算出了 `fred + jim`，
也就是 5 + 12，结果为 17。
下面是 `out.s` 中新增的几行汇编：

```
        .comm   fred,8,8                # Declare fred
        .comm   jim,8,8                 # Declare jim
        ...
        movq    $5, %r8
        movq    %r8, fred(%rip)         # fred = 5
        movq    $12, %r8
        movq    %r8, jim(%rip)          # jim = 12
        movq    fred(%rip), %r8
        movq    jim(%rip), %r9
        addq    %r8, %r9                # fred + jim
```

## 其他改动

我大概还做了一些别的修改。
目前我能记起来的一个主要变化，是在 `misc.c` 里增加了一些辅助函数，
让致命错误的报告更方便：

```c
// Print out fatal messages
void fatal(char *s) {
  fprintf(stderr, "%s on line %d\n", s, Line); exit(1);
}

void fatals(char *s1, char *s2) {
  fprintf(stderr, "%s:%s on line %d\n", s1, s2, Line); exit(1);
}

void fatald(char *s, int d) {
  fprintf(stderr, "%s:%d on line %d\n", s, d, Line); exit(1);
}

void fatalc(char *s, int c) {
  fprintf(stderr, "%s:%c on line %d\n", s, c, Line); exit(1);
}
```

## 总结与下一步

这部分确实工作量很大。
我们不得不开始编写符号表管理的雏形，
处理两种新语句，
加入一些新 token 和新的 AST 节点类型，
最后还要补上对应的 x86-64 汇编代码生成逻辑。

你可以试着自己写几个输入文件，
看看编译器是否按预期工作，
尤其是它能不能检测出语法错误和语义错误
（例如变量未声明就使用）。

在编译器编写之旅的下一部分中，
我们会给语言加入六个比较运算符。
这样一来，在后面一部分里我们就能开始实现控制结构了。 [下一步](../07_Comparisons/Readme.md)
