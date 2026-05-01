# 第 31 部分：实现结构体，第 1 部分

在编译器编写之旅的这一部分里，
我开始把 struct 真正引入语言之中。
虽然它们此时还不能完全使用，
但为了至少先走到“能够声明 struct，
并且能够声明 struct 类型的全局变量”这一步，
我已经对代码做了相当多改动。

## 符号表的变更

正如上一部分提到的，
一旦某个符号属于复合类型，
我们就必须在符号表结构里额外保存一个“指向该复合类型节点的指针”。
另外我们也已经加入了 `next` 指针来支持链表，
以及 `member` 指针。
函数节点中的 `member` 指针用于保存函数参数列表；
而对于 struct 来说，
我们会用这个 `member` 指针来保存 struct 的成员字段。

因此现在我们有：

```c
struct symtable {
  char *name;                   // Name of a symbol
  int type;                     // Primitive type for the symbol
  struct symtable *ctype;       // If needed, pointer to the composite type
  ...
  struct symtable *next;        // Next symbol in one list
  struct symtable *member;      // First member of a function, struct,
};                              // union or enum
```

同时在 `data.h` 中，
我们又新增了两条符号链表：

```c
// Symbol table lists
struct symtable *Globhead, *Globtail;     // Global variables and functions
struct symtable *Loclhead, *Locltail;     // Local variables
struct symtable *Parmhead, *Parmtail;     // Local parameters
struct symtable *Membhead, *Membtail;     // Temp list of struct/union members
struct symtable *Structhead, *Structtail; // List of struct types
```

## `sym.c` 的改动

在 `sym.c` 以及代码库其他地方，
我们以前通常只通过一个 `int type` 参数
来判断某个东西的类型。
但现在有了复合类型之后，
这就不够了：
`P_STRUCT` 这个整数值只能说明“这是个 struct”，
却不能说明“它到底是哪个 struct”。

因此，
现在很多函数除了接收 `int type` 之外，
还会额外接收一个 `struct symtable *ctype` 参数。
当 `type == P_STRUCT` 时，
`ctype` 会指向定义这个具体 struct 类型的那个节点。

在 `sym.c` 中，
所有 `addXX()` 函数都已经改成接收这个额外参数。
另外还新增了 `addmemb()` 和 `addstruct()`，
分别往这两条新链表里加入节点。
它们和其他 `addXX()` 函数在逻辑上完全相同，
只是作用于不同的链表。
后面我会再回头讲它们。

## 一个新 token

我们已经很久没有新 token 了，
这次新增的是 `P_STRUCT`，
对应关键字 `struct`。
`scan.c` 中的扫描改动都比较小，
我这里就不展开了。

## 在语法中解析 struct

我们需要在很多地方解析 `struct` 关键字：

  + 具名 struct 的定义
  + 匿名 struct 的定义，后面紧跟一个该类型变量
  + 在另一个 struct 或 union 中定义一个 struct
  + 声明一个“先前已经定义过的 struct 类型”的变量

一开始我其实不太确定该把 struct 解析挂在哪一层。
是应该先假设“这里在定义一个新的 struct”，
等看到变量标识符时再退出来；
还是应该先按变量声明去理解？

最后我意识到，
在看到 `struct <identifier>` 之后，
我们首先必须把它理解成“某种类型名”，
就像 `int` 是 `int` 类型的名字一样。
至于后面是不是紧跟着真正的定义，
得继续看下一个 token 才知道。

因此，
我修改了 `decl.c` 里的 `parse_type()`，
让它既能解析标量类型（例如 `int`），
也能解析复合类型（例如 `struct foo`）。
而现在既然它可能返回复合类型，
那我们还得想办法把“定义这个复合类型的节点指针”也一并传回来：

```c
// Parse the current token and return
// a primitive type enum value and a pointer
// to any composite type.
// Also scan in the next token
int parse_type(struct symtable **ctype) {
  int type;
  switch (Token.token) {
    ...         // Existing code for T_VOID, T_CHAR etc.
    case T_STRUCT:
      type = P_STRUCT;
      *ctype = struct_declaration();
      break;
    ...
```

这里我们调用 `struct_declaration()`，
它要么查找一个已经存在的 struct 类型，
要么解析一个新的 struct 类型声明。

## 重构变量列表的解析

旧代码里有一个叫 `param_declaration()` 的函数，
它负责解析“逗号分隔”的参数列表，例如：

```c
int fred(int x, char y, long z);
```

也就是函数声明里的参数列表。
但 struct 和 union 声明其实也会有一串变量列表，
只不过它们不是逗号分隔，
而是“分号分隔、并放在花括号里”，例如：

```c
struct fred { int x; char y; long z; };
```

所以把这个函数重构成能同时处理两种列表形式，
就很合理了。
它现在会接收两个 token：
一个是分隔 token，比如 `T_SEMI`；
另一个是结束 token，比如 `T_RBRACE`。
这样一来，
我们就能拿它去解析这两种不同风格的列表。

```c
// Parse a list of variables.
// Add them as symbols to one of the symbol table lists, and return the
// number of variables. If funcsym is not NULL, there is an existing function
// prototype, so compare each variable's type against this prototype.
static int var_declaration_list(struct symtable *funcsym, int class,
                                int separate_token, int end_token) {
    ...
    // Get the type and identifier
    type = parse_type(&ctype);
    ...
    // Add a new parameter to the right symbol table list, based on the class
    var_declaration(type, ctype, class);
}
```

当我们在解析函数参数列表时，
调用方式是：

```c
    var_declaration_list(oldfuncsym, C_PARAM, T_COMMA, T_RPAREN);
```

而在解析 struct 成员列表时，
调用方式则是：

```c
    var_declaration_list(NULL, C_MEMBER, T_SEMI, T_RBRACE);
```

同时也要注意：
现在传给 `var_declaration()` 的参数
除了变量类型之外，
还包括“复合类型指针”（如果它是 struct 或 union）
以及该变量的 class。

到这里为止，
我们已经能解析 struct 的成员列表了。
下面就来看整个 struct 到底是怎么被解析出来的。

## `struct_declaration()` 函数

我们分阶段来看。

```c
static struct symtable *struct_declaration(void) {
  struct symtable *ctype = NULL;
  struct symtable *m;
  int offset;

  // Skip the struct keyword
  scan(&Token);

  // See if there is a following struct name
  if (Token.token == T_IDENT) {
    // Find any matching composite type
    ctype = findstruct(Text);
    scan(&Token);
  }
```

到这里为止，
我们已经看到了 `struct`，
后面可能还跟着一个标识符。
如果它代表一个已存在的 struct 类型，
那 `ctype` 现在就会指向那个已有类型节点；
否则 `ctype` 仍然是 `NULL`。

```c
  // If the next token isn't an LBRACE , this is
  // the usage of an existing struct type.
  // Return the pointer to the type.
  if (Token.token != T_LBRACE) {
    if (ctype == NULL)
      fatals("unknown struct type", Text);
    return (ctype);
  }
```

如果下一个 token 不是 `{`，
那就说明这里不是在定义新的 struct，
而只是“使用一个已经存在的 struct 类型名”。
这时 `ctype` 就绝不应该还是 `NULL`，
所以先检查一下；
然后直接把这个已有类型节点指针返回即可。
它会一路回到前面 `parse_type()` 里，
也就是：

```c
      type = P_STRUCT; *ctype = struct_declaration();
```

但如果我们没有在这里提前返回，
那就说明确实看到了 `{`，
这就表示：这里正在定义一个新的 struct 类型。
继续往下看。

```c
  // Ensure this struct type hasn't been
  // previously defined
  if (ctype)
    fatals("previously defined struct", Text);

  // Build the struct node and skip the left brace
  ctype = addstruct(Text, P_STRUCT, NULL, 0, 0);
  scan(&Token);
```

同名 struct 不能定义两次，
所以这里必须先阻止这种情况。
然后构建一个新的 struct 类型节点，
并把它挂进符号表。
此时我们手头只有它的名字，
以及“它是一个 `P_STRUCT` 类型”这件事。

```c
  // Scan in the list of members and attach
  // to the struct type's node
  var_declaration_list(NULL, C_MEMBER, T_SEMI, T_RBRACE);
  rbrace();
```

这一步会去解析成员列表。
列表中的每个成员，
都会作为新的符号节点追加到
`Membhead` / `Membtail` 指向的链表上。
这条链表只是临时用的，
因为接下来的几行代码会把它挪进这个新的 struct 类型节点里：

```c
  ctype->member = Membhead;
  Membhead = Membtail = NULL;
```

到这里，
我们已经有了一个 struct 类型节点：
它有名字，
也挂好了该 struct 的成员链表。
那接下来还剩什么？
我们现在还必须算出：

  + 整个 struct 的总大小
  + 每个成员相对于 struct 基址的偏移量

这其中有一部分会受到硬件对标量内存对齐方式的影响，
因此我先把现有代码给出来，
后面再顺着函数调用链去解释。

```c
  // Set the offset of the initial member
  // and find the first free byte after it
  m = ctype->member;
  m->posn = 0;
  offset = typesize(m->type, m->ctype);
```

我们现在有了一个新函数 `typesize()`，
它可以计算任意类型的大小：
标量、指针和复合类型都行。
第一个成员的位置总是 0，
然后我们用它的大小去算出：
下一个成员理论上最早可以放到哪个字节之后。
不过从这里开始，
我们就必须考虑对齐（alignment）问题了。

举个例子，
在一个 32 位架构上，
如果 4 字节标量必须对齐到 4 字节边界：

```c
struct {
  char x;               // At offset 0
  int y;                // At offset 4, not 1
};
```

所以，
下面就是计算“后续每个成员偏移量”的代码：

```c
  // Set the position of each successive member in the struct
  for (m = m->next; m != NULL; m = m->next) {
    // Set the offset for this member
    m->posn = genalign(m->type, offset, 1);

    // Get the offset of the next free byte after this member
    offset += typesize(m->type, m->ctype);
  }
```

这里我们新增了一个 `genalign()`，
它接收“当前偏移量”和“要对齐的类型”，
返回这个类型最适合放置的下一个偏移量。
比如 `genalign(P_INT, 3, 1)`
在要求 `P_INT` 必须 4 字节对齐时，
可能就会返回 4。
至于最后那个 `1` 参数，
我很快就会解释。

因此，
`genalign()` 先为当前成员算出正确的对齐偏移，
然后我们再把该成员自己的大小加上去，
得到“下一个可用但尚未对齐”的空闲位置。

当我们把成员链表全部走完之后，
此时 `offset` 就刚好等于整个 struct 的总字节大小。
于是：

```c
  // Set the overall size of the struct
  ctype->size = offset;
  return (ctype);
}
```

## `typesize()` 函数

现在该顺着这些新函数往下看，
搞清楚它们各自做了什么。
先看 `types.c` 里的 `typesize()`：

```c
// Given a type and a composite type pointer, return
// the size of this type in bytes
int typesize(int type, struct symtable *ctype) {
  if (type == P_STRUCT)
    return(ctype->size);
  return(genprimsize(type));
}
```

如果类型是 struct，
那就直接从 struct 类型节点中取出它的大小。
否则它就是标量或指针类型，
于是交给 `genprimsize()`
（它内部又会调用平台相关的 `cgprimsize()`）
去计算大小。
这部分很直白。

## `genalign()` 和 `cgalign()` 函数

接下来就进入一些没那么好看的代码了。
给定一个类型，
以及一个还没有分配给任何东西的“未对齐偏移量”，
我们要算出：
放置这个类型值时，
下一个满足对齐要求的偏移量到底是多少。

另外我还担心，
这个逻辑以后可能也要用于栈上；
而栈是向下增长的，不是向上。
所以这里又加了第三个参数：
表示“我们要往哪个方向寻找下一个可对齐位置”。

而且对齐规则本身又是硬件相关的，
因此：

```c
int genalign(int type, int offset, int direction) {
  return (cgalign(type, offset, direction));
}
```

接着我们就去看 `cg.c` 中的 `cgalign()`：

```c
// Given a scalar type, an existing memory offset
// (which hasn't been allocated to anything yet)
// and a direction (1 is up, -1 is down), calculate
// and return a suitably aligned memory offset
// for this scalar type. This could be the original
// offset, or it could be above/below the original
int cgalign(int type, int offset, int direction) {
  int alignment;

  // We don't need to do this on x86-64, but let's
  // align chars on any offset and align ints/pointers
  // on a 4-byte alignment
  switch(type) {
    case P_CHAR: return (offset);
    case P_INT:
    case P_LONG: break;
    default:     fatald("Bad type in calc_aligned_offset:", type);
  }

  // Here we have an int or a long. Align it on a 4-byte offset
  // I put the generic code here so it can be reused elsewhere.
  alignment= 4;
  offset = (offset + direction * (alignment-1)) & ~(alignment-1);
  return (offset);
}
```

首先先说一句，
我知道在 x86-64 上其实根本不必担心这些对齐问题。
但我还是觉得，
最好把这套逻辑先走一遍，
至少给未来其他后端留一个现成参考。

对 `char` 类型，
函数直接返回原偏移，
因为它本来就可以放在任意对齐位置。
而对 `int` 和 `long`，
我们这里强制它们按 4 字节对齐。

下面拆一下那条大的偏移计算表达式。
前面的 `alignment-1`
会把 `offset` 为 0 变成 3，
1 变成 4，
2 变成 5，
以此类推。
然后最后再和 `~3`
也就是形如 `...111111100`
做一次 AND，
把低两位清掉，
从而把值拉回到正确的对齐位置。

所以结果会是：

| Offset | Add Value | New Offset |
|:------:|:---------:|:----------:|
|   0    |    3      |    0       |
|   1    |    4      |    4       |
|   2    |    5      |    4       |
|   3    |    6      |    4       |
|   4    |    7      |    4       |
|   5    |    8      |    8       |
|   6    |    9      |    8       |
|   7    |   10      |    8       |

偏移 0 会继续保持 0；
但 1 到 3 都会被推到 4。
偏移 4 自己本来就对齐；
而 5 到 7 则会被推到 8。

下面来看这个函数里真正比较有魔法感的部分。
当 `direction == 1` 时，
它的行为就是上面我们刚分析的这种“向上找对齐”。
而当 `direction == -1` 时，
它就会反过来往另一个方向对齐，
确保这个值的“高地址端”不会撞到它上面那块空间：

| Offset | Add Value | New Offset |
|:------:|:---------:|:----------:|
|   0    |   -3      |   -4       |
|  -1    |   -4      |   -4       |
|  -2    |   -5      |   -8       |
|  -3    |   -6      |   -8       |
|  -4    |   -7      |   -8       |
|  -5    |   -8      |   -8       |
|  -6    |   -9      |   -12      |
|  -7    |  -10      |   -12      |

## 创建一个全局 struct 变量

既然现在我们已经能解析 struct 类型，
并且也能声明这个类型的全局变量，
那就该修改代码，
让它真的为这种全局变量分配内存空间了：

```c
// Generate a global symbol but not functions
void cgglobsym(struct symtable *node) {
  int size;

  if (node == NULL) return;
  if (node->stype == S_FUNCTION) return;

  // Get the size of the type
  size = typesize(node->type, node->ctype);

  // Generate the global identity and the label
  cgdataseg();
  fprintf(Outfile, "\t.globl\t%s\n", node->name);
  fprintf(Outfile, "%s:", node->name);

  // Generate the space for this type
  switch (size) {
    case 1: fprintf(Outfile, "\t.byte\t0\n"); break;
    case 4: fprintf(Outfile, "\t.long\t0\n"); break;
    case 8: fprintf(Outfile, "\t.quad\t0\n"); break;
    default:
      for (int i=0; i < size; i++)
        fprintf(Outfile, "\t.byte\t0\n");
  }
}
  
```

## 试试这些改动

除了“能解析 struct”之外，
我们目前还没有真正新增太多功能。
现在能做的主要是：
解析 struct、
把新节点存进符号表，
以及为全局 struct 变量生成存储空间。

我这里有一个测试程序 `z.c`：

```c
struct fred { int x; char y; long z; };
struct foo { char y; long z; } var1;
struct { int x; };
struct fred var2;
```

它应该会创建两个全局变量 `var1` 和 `var2`。
这里我们定义了两个具名 struct 类型：`fred` 和 `foo`，
以及一个匿名 struct。
第三个 struct 理论上应该报错
（至少也该有个 warning），
因为它没有绑定任何变量，
所以这个 struct 本身其实毫无用途。

我又加了一点测试代码，
把这些 struct 的成员偏移和整体大小打印出来，
结果如下：

```
Offset for fred.x is 0
Offset for fred.y is 4
Offset for fred.z is 8
Size of struct fred is 13

Offset for foo.y is 0
Offset for foo.z is 4
Size of struct foo is 9

Offset for struct.x is 0
Size of struct struct is 4
```

最后，
当我执行 `./cwj -S z.c` 时，
得到的汇编输出如下：

```
        .globl  var1
var1:   .byte   0       // Nine bytes
        ...

        .globl  var2    // Thirteen bytes
var2:   .byte   0
        ...
```

## 总结与下一步

这一部分里，
我不得不把大量旧代码
从“只处理一个 `int type`”
改成“同时处理 `int type; struct symtable *ctype` 这一对信息”。
我很确定后面还得在更多地方做类似改造。

我们现在已经能解析 struct 定义，
也能声明 struct 变量，
并为全局 struct 变量分配空间。
不过眼下我们还不能真正使用这些 struct 变量。
但这是个不错的开始。
而且我还完全没碰局部 struct 变量，
因为那会牵涉栈，
我很确定它会相当复杂。

在编译器编写之旅的下一部分中，
我会尝试真正去访问 struct 成员。 [下一步](../32_Struct_Access_pt1/Readme.md)
