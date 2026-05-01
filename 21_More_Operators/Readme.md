# 第 21 部分：更多运算符

在编译器编写之旅的这一部分里，
我决定先摘一些“低垂的果子”，
把很多还没支持的表达式运算符补上。
其中包括：

+ `++` 和 `--`，既包括前置自增 / 自减，也包括后置自增 / 自减
+ 一元 `-`、`~` 和 `!`
+ 二元 `^`、`&`、`|`、`<<` 与 `>>`

我还实现了一个隐式的“非零运算符”，
它会把表达式的 rvalue 当作布尔值（boolean value）来使用，
这样选择语句和循环语句里就可以写出例如：

```c
  for (str= "Hello"; *str; str++) ...
```

而不用写成：

```c
  for (str= "Hello"; *str != 0; str++) ...
```

## token 与扫描

和往常一样，
先从语言里新增的 token 开始。
这次有好几个：

| Scanned Input | Token |
|:-------------:|-------|
|   <code>&#124;&#124;</code>        | T_LOGOR |
|   `&&`        | T_LOGAND |
|   <code>&#124;</code>         | T_OR |
|   `^`         | T_XOR |
|   `<<`        | T_LSHIFT |
|   `>>`        | T_RSHIFT |
|   `++`        | T_INC |
|   `--`        | T_DEC |
|   `~`         | T_INVERT |
|   `!`         | T_LOGNOT |

其中有些由全新的单字符组成，
这类扫描逻辑很好写。
而另一些则需要区分“单字符”和“由两个字符组成的 token”。
比如 `<`、`<<` 和 `<=`。
我们之前已经在 `scan.c` 里处理过类似情况，
所以这里就不再把新代码全部展开了。
直接去翻 `scan.c`，
就能看到新增部分。

## 把二元运算符加入解析流程

接下来要解析这些运算符。
其中一部分是二元运算符：
`||`、`&&`、`|`、`^`、`<<` 和 `>>`。
我们已经有一套二元运算符优先级框架，
所以只要把这些新运算符接进去就行。

在做这一步时，
我发现自己之前好几个已有运算符的优先级其实都放错了，
和
[这张 C 运算符优先级表](https://en.cppreference.com/w/c/language/operator_precedence)
对不上。
同时，
AST 节点操作类型也需要和这些二元运算符 token 一一对齐。
因此，下面是 `defs.h` 和 `expr.c` 中
token 定义、AST 节点类型以及运算符优先级表的样子：

```c
// Token types
enum {
  T_EOF,
  // Binary operators
  T_ASSIGN, T_LOGOR, T_LOGAND, 
  T_OR, T_XOR, T_AMPER, 
  T_EQ, T_NE,
  T_LT, T_GT, T_LE, T_GE,
  T_LSHIFT, T_RSHIFT,
  T_PLUS, T_MINUS, T_STAR, T_SLASH,

  // Other operators
  T_INC, T_DEC, T_INVERT, T_LOGNOT,
  ...
};

// AST node types. The first few line up
// with the related tokens
enum {
  A_ASSIGN= 1, A_LOGOR, A_LOGAND, A_OR, A_XOR, A_AND,
  A_EQ, A_NE, A_LT, A_GT, A_LE, A_GE, A_LSHIFT, A_RSHIFT,
  A_ADD, A_SUBTRACT, A_MULTIPLY, A_DIVIDE,
  ...
  A_PREINC, A_PREDEC, A_POSTINC, A_POSTDEC,
  A_NEGATE, A_INVERT, A_LOGNOT,
  ...
};

// Operator precedence for each binary token. Must
// match up with the order of tokens in defs.h
static int OpPrec[] = {
  0, 10, 20, 30,                // T_EOF, T_ASSIGN, T_LOGOR, T_LOGAND
  40, 50, 60,                   // T_OR, T_XOR, T_AMPER 
  70, 70,                       // T_EQ, T_NE
  80, 80, 80, 80,               // T_LT, T_GT, T_LE, T_GE
  90, 90,                       // T_LSHIFT, T_RSHIFT
  100, 100,                     // T_PLUS, T_MINUS
  110, 110                      // T_STAR, T_SLASH
};
```

## 新的一元运算符

现在轮到解析新的单目 / 一元运算符：
`++`、`--`、`~` 和 `!`。
这些里有些是前缀运算符（prefix operator），
也就是出现在表达式前面；
而 `++` 和 `--` 同时也可以是后缀运算符（postfix operator）。
因此，
我们需要解析三个前缀运算符和两个后缀运算符，
并为它们执行五种不同的语义动作。

为了给这些新运算符做准备，
我重新查了前面提到的
[C 的 BNF 语法](https://www.lysator.liu.se/c/ANSI-C-grammar-y.html)。
由于这些新运算符没法简单塞进现有的二元运算符优先级框架，
所以我们需要在递归下降解析器里新增一些函数。
下面是其中和当前需求*相关*的部分，
我把它改写成了使用我们自己 token 名称的形式：

```
primary_expression
        : T_IDENT
        | T_INTLIT
        | T_STRLIT
        | '(' expression ')'
        ;

postfix_expression
        : primary_expression
        | postfix_expression '[' expression ']'
        | postfix_expression '(' expression ')'
        | postfix_expression '++'
        | postfix_expression '--'
        ;

prefix_expression
        : postfix_expression
        | '++' prefix_expression
        | '--' prefix_expression
        | prefix_operator prefix_expression
        ;

prefix_operator
        : '&'
        | '*'
        | '-'
        | '~'
        | '!'
        ;

multiplicative_expression
        : prefix_expression
        | multiplicative_expression '*' prefix_expression
        | multiplicative_expression '/' prefix_expression
        | multiplicative_expression '%' prefix_expression
        ;

        etc.
```

我们目前在 `expr.c` 里通过 `binexpr()` 处理二元运算符，
而它内部会调用 `prefix()`；
这正对应上面 BNF 中
`multiplicative_expression` 引用 `prefix_expression` 的关系。
我们已经有 `primary()` 了，
现在还需要一个 `postfix()` 来处理后缀表达式。

## 前缀运算符

我们本来就在 `prefix()` 里解析了两个 token：
`T_AMPER` 和 `T_STAR`。
现在只需要在 `switch (Token.token)` 里
再多加几个分支，
把 `T_MINUS`、`T_INVERT`、`T_LOGNOT`、`T_INC` 和 `T_DEC`
也接进去。

这里我就不把完整代码全贴出来了，
因为这些 case 的整体结构都差不多：

  + 用 `scan(&Token)` 跳过当前 token
  + 用 `prefix()` 继续解析后面的表达式
  + 做一些语义检查（semantic checking）
  + 扩展刚刚返回的 AST 树

不过，
其中几个 case 的差异还是值得单独说明。
对于 `&`（`T_AMPER`），
表达式必须被视为 lvalue：
如果我们写 `&x`，
想要的是变量 `x` 的地址，
而不是 `x` 当前值的地址。
而其他一些情况则必须强制把 `prefix()` 返回的 AST 树视为 rvalue，
包括：

  + `-`（`T_MINUS`）
  + `~`（`T_INVERT`）
  + `!`（`T_LOGNOT`）

另外，对于前置自增和前置自减，
我们实际上要求这个表达式必须是 lvalue：
可以写 `++x`，
但不能写 `++3`。
目前我先把代码写成“只接受简单标识符”的形式，
但我很清楚，
后面我们还得支持 `++b[2]` 以及 `++ *ptr` 这样的写法。

从设计角度看，
这里有两种做法：
要么直接修改 `prefix()` 返回的 AST 树，
不引入新节点；
要么在树上再包一层或多层新的 AST 节点。

  + `T_AMPER` 会修改已有 AST 树，使其根节点变成 `A_ADDR`
  + `T_STAR` 会在树根外面再包一层 `A_DEREF`
  + `T_MINUS` 会在树根外面再包一层 `A_NEGATE`，
    并且必要时先把表达式扩宽成 `int`。为什么？
    因为这棵树有可能是 `char` 类型，而 `char` 在这里是无符号的，
    无符号值没法直接取负。
  + `T_INVERT` 会在树根外面包一层 `A_INVERT`
  + `T_LOGNOT` 会在树根外面包一层 `A_LOGNOT`
  + `T_INC` 会在树根外面包一层 `A_PREINC`
  + `T_DEC` 会在树根外面包一层 `A_PREDEC`

## 解析后缀运算符

如果你回头看我上面引用的 BNF，
会发现“后缀表达式”的解析需要依赖“主表达式（primary expression）”。
因此实现时，
我们得先把主表达式的 token 读出来，
再判断后面有没有跟着后缀 token。

虽然语法写法看起来像是“postfix 调用 primary”，
但我的实现方式是：
先在 `primary()` 里把基础 token 识别出来，
然后再决定是否调用 `postfix()` 去解析后缀部分。

> 事实证明这是个错误决定。  
> 这是来自未来的 Warren 给现在的注释。

上面的 BNF 看上去甚至允许出现 `x++ ++` 这样的表达式，
因为它写的是：

```
postfix_expression:
        postfix_expression '++'
        ;
```

不过我这里并不打算允许在一个表达式后面连着跟多个后缀运算符。
那就来看看新代码。

`primary()` 负责识别主表达式：
整数字面量、字符串字面量和标识符，
也包括带括号的表达式。
而只有标识符后面才可能继续跟着后缀运算符。

```c
static struct ASTnode *primary(void) {
  ...
  switch (Token.token) {
    case T_INTLIT: ...
    case T_STRLIT: ...
    case T_LPAREN: ...
    case T_IDENT:
      return (postfix());
    ...
}
```

我把“函数调用”和“数组下标访问”的解析逻辑
都从 `primary()` 挪到了 `postfix()` 里，
并且也是在这里加入了后缀 `++` 与 `--` 的支持：

```c
// Parse a postfix expression and return
// an AST node representing it. The
// identifier is already in Text.
static struct ASTnode *postfix(void) {
  struct ASTnode *n;
  int id;

  // Scan in the next token to see if we have a postfix expression
  scan(&Token);

  // Function call
  if (Token.token == T_LPAREN)
    return (funccall());

  // An array reference
  if (Token.token == T_LBRACKET)
    return (array_access());


  // A variable. Check that the variable exists.
  id = findglob(Text);
  if (id == -1 || Gsym[id].stype != S_VARIABLE)
    fatals("Unknown variable", Text);

  switch (Token.token) {
      // Post-increment: skip over the token
    case T_INC:
      scan(&Token);
      n = mkastleaf(A_POSTINC, Gsym[id].type, id);
      break;

      // Post-decrement: skip over the token
    case T_DEC:
      scan(&Token);
      n = mkastleaf(A_POSTDEC, Gsym[id].type, id);
      break;

      // Just a variable reference
    default:
      n = mkastleaf(A_IDENT, Gsym[id].type, id);
  }
  return (n);
}
```

这里还有一个设计决策。
对于 `++`，
我们原本也可以把它做成一个 `A_IDENT` AST 节点，
外面再包一个 `A_POSTINC` 父节点。
但既然当前标识符名字已经在 `Text` 里，
那我们完全可以直接构造一个 AST 节点，
同时把“节点类型”和“符号表槽位编号”都塞进去。

## 把整数表达式转换成布尔值

在离开“解析”这一侧，
转向“代码生成”之前，
我还得提一下我为了让“整数表达式也能当布尔表达式使用”而做的改动。
比如：

```
  x= a + b;
  if (x) { printf("x is not zero\n"); }
```

BNF 语法里并没有显式规定
“这里必须是布尔表达式”之类的额外限制，
例如：

```
selection_statement
        : IF '(' expression ')' statement
```

因此这件事只能通过语义层来处理。
在 `stmt.c` 里解析 `IF`、`WHILE` 和 `FOR` 循环时，
我加了下面这段代码：

```c
  // Parse the following expression
  // Force a non-comparison expression to be boolean
  condAST = binexpr(0);
  if (condAST->op < A_EQ || condAST->op > A_GE)
    condAST = mkastunary(A_TOBOOL, condAST->type, condAST, 0);
```

这里我新增了一种 AST 节点类型：`A_TOBOOL`。
它会生成代码，
把任意整数值转换成布尔值：
如果原值是 0，
结果就是 0；
否则结果就是 1。

## 为新运算符生成代码

现在把注意力转到这些新运算符的代码生成上。
更准确地说，
是这些新的 AST 节点类型：
`A_LOGOR`、`A_LOGAND`、`A_OR`、`A_XOR`、`A_AND`、
`A_LSHIFT`、`A_RSHIFT`、`A_PREINC`、`A_PREDEC`、
`A_POSTINC`、`A_POSTDEC`、`A_NEGATE`、`A_INVERT`、
`A_LOGNOT` 和 `A_TOBOOL`。

这些节点在 `gen.c` 的 `genAST()` 里，
基本都只是简单地转发到平台相关代码生成器 `cg.c`
中的同名 / 对应函数。
因此新增代码几乎就是：

```c
    case A_AND:
      return (cgand(leftreg, rightreg));
    case A_OR:
      return (cgor(leftreg, rightreg));
    case A_XOR:
      return (cgxor(leftreg, rightreg));
    case A_LSHIFT:
      return (cgshl(leftreg, rightreg));
    case A_RSHIFT:
      return (cgshr(leftreg, rightreg));
    case A_POSTINC:
      // Load the variable's value into a register,
      // then increment it
      return (cgloadglob(n->v.id, n->op));
    case A_POSTDEC:
      // Load the variable's value into a register,
      // then decrement it
      return (cgloadglob(n->v.id, n->op));
    case A_PREINC:
      // Load and increment the variable's value into a register
      return (cgloadglob(n->left->v.id, n->op));
    case A_PREDEC:
      // Load and decrement the variable's value into a register
      return (cgloadglob(n->left->v.id, n->op));
    case A_NEGATE:
      return (cgnegate(leftreg));
    case A_INVERT:
      return (cginvert(leftreg));
    case A_LOGNOT:
      return (cglognot(leftreg));
    case A_TOBOOL:
      // If the parent AST node is an A_IF or A_WHILE, generate
      // a compare followed by a jump. Otherwise, set the register
      // to 0 or 1 based on it's zeroeness or non-zeroeness
      return (cgboolean(leftreg, parentASTop, label));
```

## x86-64 专用代码生成函数

这意味着，
我们现在可以去看后端如何真正生成 x86-64 汇编代码了。
对大多数按位运算（bitwise operation）来说，
x86-64 平台本身就有对应的汇编指令：

```c
int cgand(int r1, int r2) {
  fprintf(Outfile, "\tandq\t%s, %s\n", reglist[r1], reglist[r2]);
  free_register(r1); return (r2);
}

int cgor(int r1, int r2) {
  fprintf(Outfile, "\torq\t%s, %s\n", reglist[r1], reglist[r2]);
  free_register(r1); return (r2);
}

int cgxor(int r1, int r2) {
  fprintf(Outfile, "\txorq\t%s, %s\n", reglist[r1], reglist[r2]);
  free_register(r1); return (r2);
}

// Negate a register's value
int cgnegate(int r) {
  fprintf(Outfile, "\tnegq\t%s\n", reglist[r]); return (r);
}

// Invert a register's value
int cginvert(int r) {
  fprintf(Outfile, "\tnotq\t%s\n", reglist[r]); return (r);
}
```

至于移位运算，
据我所知，
移位量必须先装进 `%cl` 寄存器。

```c
int cgshl(int r1, int r2) {
  fprintf(Outfile, "\tmovb\t%s, %%cl\n", breglist[r2]);
  fprintf(Outfile, "\tshlq\t%%cl, %s\n", reglist[r1]);
  free_register(r2); return (r1);
}

int cgshr(int r1, int r2) {
  fprintf(Outfile, "\tmovb\t%s, %%cl\n", breglist[r2]);
  fprintf(Outfile, "\tshrq\t%%cl, %s\n", reglist[r1]);
  free_register(r2); return (r1);
}
```

而那些和布尔表达式有关的操作
（即结果必须是 0 或 1 的情况），
则稍微复杂一些。

```c
// Logically negate a register's value
int cglognot(int r) {
  fprintf(Outfile, "\ttest\t%s, %s\n", reglist[r], reglist[r]);
  fprintf(Outfile, "\tsete\t%s\n", breglist[r]);
  fprintf(Outfile, "\tmovzbq\t%s, %s\n", breglist[r], reglist[r]);
  return (r);
}
```

`test` 指令本质上会把寄存器和它自己做一次 AND，
以设置零标志和负号标志。
然后如果结果等于 0，
我们就用 `sete` 把对应寄存器字节设为 1。
最后再把这个 8 位结果扩展搬运到完整的 64 位寄存器里。

下面则是把一个整数转换成布尔值的代码：

```c
// Convert an integer value to a boolean value. Jump if
// it's an IF or WHILE operation
int cgboolean(int r, int op, int label) {
  fprintf(Outfile, "\ttest\t%s, %s\n", reglist[r], reglist[r]);
  if (op == A_IF || op == A_WHILE)
    fprintf(Outfile, "\tje\tL%d\n", label);
  else {
    fprintf(Outfile, "\tsetnz\t%s\n", breglist[r]);
    fprintf(Outfile, "\tmovzbq\t%s, %s\n", breglist[r], reglist[r]);
  }
  return (r);
}
```

这里同样先做一次 `test`，
得到该寄存器值是零还是非零的信息。
如果这是为 `if` 或 `while` 语句生成的代码，
那就用 `je` 在结果为假时跳转。
否则就用 `setnz`，
在原值非零时把寄存器设为 1。

## 自增与自减操作

我把 `++` 和 `--` 留到最后来讲。
这里的微妙之处在于：
我们既要把内存位置里的值取到寄存器中，
又要单独对原内存位置执行加一或减一。
而且还得根据是前置还是后置，
决定“先改再取”还是“先取再改”。

既然我们已经有 `cgloadglob()`，
专门用来加载全局变量的值，
那就干脆把它改造一下，
让它在需要时顺便修改变量。
这段代码不算好看，
但确实能工作：

```c
// Load a value from a variable into a register.
// Return the number of the register. If the
// operation is pre- or post-increment/decrement,
// also perform this action.
int cgloadglob(int id, int op) {
  // Get a new register
  int r = alloc_register();

  // Print out the code to initialise it
  switch (Gsym[id].type) {
    case P_CHAR:
      if (op == A_PREINC)
        fprintf(Outfile, "\tincb\t%s(\%%rip)\n", Gsym[id].name);
      if (op == A_PREDEC)
        fprintf(Outfile, "\tdecb\t%s(\%%rip)\n", Gsym[id].name);
      fprintf(Outfile, "\tmovzbq\t%s(%%rip), %s\n", Gsym[id].name, reglist[r]);
      if (op == A_POSTINC)
        fprintf(Outfile, "\tincb\t%s(\%%rip)\n", Gsym[id].name);
      if (op == A_POSTDEC)
        fprintf(Outfile, "\tdecb\t%s(\%%rip)\n", Gsym[id].name);
      break;
    case P_INT:
      if (op == A_PREINC)
        fprintf(Outfile, "\tincl\t%s(\%%rip)\n", Gsym[id].name);
      if (op == A_PREDEC)
        fprintf(Outfile, "\tdecl\t%s(\%%rip)\n", Gsym[id].name);
      fprintf(Outfile, "\tmovslq\t%s(\%%rip), %s\n", Gsym[id].name, reglist[r]);
      if (op == A_POSTINC)
        fprintf(Outfile, "\tincl\t%s(\%%rip)\n", Gsym[id].name);
      if (op == A_POSTDEC)
        fprintf(Outfile, "\tdecl\t%s(\%%rip)\n", Gsym[id].name);
      break;
    case P_LONG:
    case P_CHARPTR:
    case P_INTPTR:
    case P_LONGPTR:
      if (op == A_PREINC)
        fprintf(Outfile, "\tincq\t%s(\%%rip)\n", Gsym[id].name);
      if (op == A_PREDEC)
        fprintf(Outfile, "\tdecq\t%s(\%%rip)\n", Gsym[id].name);
      fprintf(Outfile, "\tmovq\t%s(\%%rip), %s\n", Gsym[id].name, reglist[r]);
      if (op == A_POSTINC)
        fprintf(Outfile, "\tincq\t%s(\%%rip)\n", Gsym[id].name);
      if (op == A_POSTDEC)
        fprintf(Outfile, "\tdecq\t%s(\%%rip)\n", Gsym[id].name);
      break;
    default:
      fatald("Bad type in cgloadglob:", Gsym[id].type);
  }
  return (r);
}
```

我几乎可以肯定，
以后为了处理像 `x= b[5]++` 这样的情况，
这里还得重写。
不过现在先这样已经够用了。
毕竟我本来也说过，
这趟旅程的每一步都会先走婴儿步。

## 测试新功能

这一部分我就不把新的测试输入文件逐个展开讲了。
它们分别是 `tests` 目录下的 `input22.c`、`input23.c` 和 `input24.c`。
你可以自己去看，
并确认编译器现在已经能正确编译它们：

```
$ make test
...
input22.c: OK
input23.c: OK
input24.c: OK
```

## 总结与下一步

如果从“扩展编译器功能”的角度看，
这一部分确实一下子加进来了不少能力；
但我希望它额外引入的概念复杂度并不算太高。

我们加入了一批新的二元运算符，
实现方式主要是更新扫描器，
并调整运算符优先级表。

对于一元运算符，
我们是在解析器的 `prefix()` 里手工加入的。

而对于新的后缀运算符，
我们把原先函数调用和数组下标访问的逻辑
拆进了新的 `postfix()` 函数，
再借此把后缀运算符也一并加进去。
这里确实需要稍微留心 lvalue 和 rvalue，
同时也得做一些设计取舍：
到底该新增哪些 AST 节点，
还是只给已有节点重新“挂属性”。

代码生成这边最终相对简单，
因为 x86-64 架构本身已经提供了我们所需的大部分指令。
不过，
有些操作仍然需要先准备特定寄存器，
或者用几条指令组合起来达成目标。

真正比较棘手的是自增和自减操作。
我现在已经让它们在普通变量上工作起来了，
但后面还得再回来处理更复杂的情况。

在编译器编写之旅的下一部分中，
我想先解决局部变量（local variable）。
一旦这块跑通，
我们就可以顺势扩展到函数形参（parameter）和实参（argument）。
这大概要分成两步或更多步来完成。 [下一步](../22_Design_Locals/Readme.md)
