# 第 40 部分：全局变量初始化

在上一部分的编译器编写之旅里，
我已经为语言加入“变量声明时顺带初始化”
这件事打下了基础。
而在这一部分里，
我终于把它实现到了
全局标量变量和全局数组变量上。

与此同时，
我也意识到，
自己一开始设计的符号表结构，
并不能很好地表示“变量本身的大小”
以及“数组变量的元素个数”。
所以这一部分大约有一半内容，
其实是在重写一批与符号表相关的代码。

## 先快速回顾一下全局变量赋值

先快速回顾一下，
下面这些是我希望支持的全局变量赋值示例：

```c
int x= 2;
char y= 'a';
char *str= "Hello world";
int a[10];
char b[]= { 'q', 'w', 'e', 'r', 't', 'y' };
char c[10]= { 'q', 'w', 'e', 'r', 't', 'y' };   // Zero padded
char *d[]= { "apple", "banana", "peach", "pear" };
```

我暂时不打算处理
全局 struct 或 union 的初始化。
另外，
暂时也还不打算支持把 `NULL`
放进 `char *` 变量里。
如果后面确实需要，
我再回头补。

## 我们要往哪里走

在上一部分里，
我曾经在 `decl.c` 中写下过这样一段代码：

```c
static struct symtable *symbol_declaration(...) {
  ...
  // The array or scalar variable is being initialised
  if (Token.token == T_ASSIGN) {
    ...
        // Array initialisation
    if (stype == S_ARRAY)
      array_initialisation(sym, type, ctype, class);
    else {
      fatal("Scalar variable initialisation not done yet");
      // Variable initialisation
      // if (class== C_LOCAL)
      // Local variable, parse the expression
      // expr= binexpr(0);
      // else write more code!
    }
  }
  ...
}
```

也就是说，
我当时已经知道代码应该塞在哪个位置，
但还不知道到底该写些什么。
第一步，
我们先得学会解析一些字面量值。

## 标量变量初始化

我们需要能够解析整数字面量和字符串字面量，
因为对全局变量来说，
目前可赋值的也就这两种东西。
同时还必须确保：
字面量的类型和要赋值的变量类型彼此兼容。
为此，
`decl.c` 中新增了一个函数：

```c
// Given a type, check that the latest token is a literal
// of that type. If an integer literal, return this value.
// If a string literal, return the label number of the string.
// Do not scan the next token.
int parse_literal(int type) {

  // We have a string literal. Store in memory and return the label
  if ((type == pointer_to(P_CHAR)) && (Token.token == T_STRLIT))
    return(genglobstr(Text));

  if (Token.token == T_INTLIT) {
    switch(type) {
      case P_CHAR: if (Token.intvalue < 0 || Token.intvalue > 255)
                     fatal("Integer literal value too big for char type");
      case P_INT:
      case P_LONG: break;
      default: fatal("Type mismatch: integer literal vs. variable");
    }
  } else
    fatal("Expecting an integer literal value");
  return(Token.intvalue);
}
```

第一条 `if` 语句确保我们可以写出：

```c
char *str= "Hello world";
```

而它返回的，
则是这个字符串在内存中存放位置所对应的标签号。

至于整数字面量，
当它要赋给 `char` 变量时，
我们会额外检查数值范围。
如果遇到其它不合法 token，
就直接报 fatal 错误。

## 对符号表结构的修改

上面的函数无论解析的是哪种字面量，
最终都统一返回一个整数。
所以接下来，
我们需要在每个变量对应的符号表项里
预留一个地方来保存这些值。
因此我在 `defs.h` 的符号结构里新增了
（以及 / 或者调整了）
这些字段：

```c
// Symbol table structure
struct symtable {
  ...
  int size;              // Total size in bytes of this symbol
  int nelems;            // Functions: # params. Arrays: # elements
  ...
  int *initlist;         // List of initial values
  ...
};
```

对于只有一个初始值的标量，
或者拥有多个初始值的数组，
我们都把元素个数放进 `nelems`，
并把一串整型值挂到 `initlist` 上。
下面先来看标量变量赋值。

## 标量变量赋值

`scalar_declaration()` 现在被改成了这样：

```c
static struct symtable *scalar_declaration(...) {
  ...
    // The variable is being initialised
  if (Token.token == T_ASSIGN) {
    // Only possible for a global or local
    if (class != C_GLOBAL && class != C_LOCAL)
      fatals("Variable can not be initialised", varname);
    scan(&Token);

    // Globals must be assigned a literal value
    if (class == C_GLOBAL) {
      // Create one initial value for the variable and
      // parse this value
      sym->initlist= (int *)malloc(sizeof(int));
      sym->initlist[0]= parse_literal(type);
      scan(&Token);
    }                           // No else code yet, soon
  }

  // Generate any global space
  if (class == C_GLOBAL)
    genglobsym(sym);

  return (sym);
}
```

这里先确保：
只有在全局作用域或局部作用域中，
变量才允许被初始化。
随后跳过 `'='` token。

如果当前是全局变量，
那就为它创建一个长度正好为 1 的 `initlist`，
再调用 `parse_literal()`
按变量类型把字面量值
（或者字符串标签号）
读出来存进去。
然后继续扫描下一个 token，
此时它应该是 `','` 或 `';'`。

之前，
`sym` 这个符号表项
是在调用 `addglob()` 时创建的，
并且元素个数直接被设成了 1。
这个变化我等会儿再讲。

另外，
之前放在 `addglob()` 里的 `genglobsym()` 调用，
现在被我移到了这里。
也就是说，
我们会等到初始值真正写进 `sym` 表项之后，
才去调用 `genglobsym()`。
这样就能确保：
刚才解析出来的字面量值
会被正确写入变量对应的那块内存空间里。

### 标量初始化示例

举个简单例子：

```c
int x= 5;
char *y= "Hello";
```

会生成：

```
        .globl  x
x:
        .long   5

L1:
        .byte   72
        .byte   101
        .byte   108
        .byte   108
        .byte   111
        .byte   0

        .globl  y
y:
        .quad   L1
```

## 对符号表代码的修改

在进入数组初始化之前，
我们得先绕一下路，
看看符号表代码为了配合这件事都做了什么调整。
正如前面提到的，
我最初那套代码
并不能正确保存“变量大小”
以及“数组元素个数”。
下面来看看我是怎么修的。

首先有一个 bug 修复。
在 `types.c` 中：

```c
// Return true if a type is an int type
// of any size, false otherwise
int inttype(int type) {
  return (((type & 0xf) == 0) && (type >= P_CHAR && type <= P_LONG));
}
```

之前这里没有去检查 `P_CHAR`，
结果导致 `void` 类型
竟然也会被当成整数类型。
真离谱。

而在 `sym.c` 中，
现在我们已经明确要处理：
每个变量都有下面这两个字段：

```c
  int size;                     // Total size in bytes of this symbol
  int nelems;                   // Functions: # params. Arrays: # elements
```

后面，
`size` 字段还会被 `sizeof()` 运算符拿来用。
所以现在，
无论是把符号加入全局符号表还是局部符号表，
都必须同时设置好这两个字段。

`sym.c` 里的 `newsym()` 函数
以及所有 `addXX()` 系列函数，
现在接收的已经不再是 `size` 参数，
而是 `nelems` 参数。
对标量变量来说，
它被设为 1；
对数组来说，
它是数组里的元素数量；
对函数来说，
它是函数参数个数；
而对其它类型的符号表项，
这个值则暂时没什么意义。

`size` 的计算现在统一放进 `newsym()` 里：

```c
  // For pointers and integer types, set the size
  // of the symbol. structs and union declarations
  // manually set this up themselves.
  if (ptrtype(type) || inttype(type))
    node->size = nelems * typesize(type, ctype);
```

`typesize()` 会通过 `ctype` 指针
去拿 struct 或 union 的大小；
如果是指针或整数类型，
则会调用 `genprimsize()`
（后者再去调用 `cgprimsize()`）
得到对应大小。

注意上面注释里提到的 struct 和 union。
我们没法在调用 `addstruct()`
（它内部会再调用 `newsym()`）时，
就把 struct 的大小一并传进去，
因为：

```c
struct foo {            // We call addglob() here
  int x;
  int y;                // before we know the size of the structure
  int z;
};
```

当我们刚开始处理这个声明时，
实际上还根本不知道整个结构体有多大。
所以 `decl.c` 里的 `composite_declaration()` 现在会这么做：

```c
static struct symtable *composite_declaration(...) {
  ...
  // Build the composite type
  if (type == P_STRUCT)
    ctype = addstruct(Text);
  else
    ctype = addunion(Text);
  ...
  // Scan in the list of members
  while (1) {
    ...
  }

  // Attach to the struct type's node
  ctype->member = Membhead;
  ...

  // Set the overall size of the composite type
  ctype->size = offset;
  return (ctype);
}
```

所以总结一下，
现在符号表项里的 `size` 字段，
保存的是“这个变量所有元素合起来占用的总字节数”；
而 `nelems` 保存的是“元素个数”：
对标量来说是 1，
对数组来说则是某个非零正整数。

## 数组变量初始化

终于轮到数组初始化了。
我希望允许下面三种形式：

```c
int a[10];                                      // Ten zeroed elements
char b[]= { 'q', 'w', 'e', 'r', 't', 'y' };     // Six elements
char c[10]= { 'q', 'w', 'e', 'r', 't', 'y' };   // Ten elements, zero padded
```

但如果一个数组被声明为大小 *N*，
却给了超过 *N* 个初始化值，
那就必须阻止。
下面来看 `array_declaration()` 的改动。

之前我本来打算额外写一个 `array_initialisation()` 函数，
但后来决定：
干脆把所有初始化相关代码
直接并回 `decl.c` 里的 `array_declaration()`。
下面分阶段看。

```c
// Given the type, name and class of an variable, parse
// the size of the array, if any. Then parse any initialisation
// value and allocate storage for it.
// Return the variable's symbol table entry.
static struct symtable *array_declaration(...) {
  int nelems= -1;       // Assume the number of elements won't be given
  ...
  // Skip past the '['
  scan(&Token);

  // See we have an array size
  if (Token.token == T_INTLIT) {
    if (Token.intvalue <= 0)
      fatald("Array size is illegal", Token.intvalue);
    nelems= Token.intvalue;
    scan(&Token);
  }

  // Ensure we have a following ']'
  match(T_RBRACKET, "]");
```

如果 `'['` 和 `']'` 之间给了一个数字，
就把它解析出来并记录到 `nelems`。
如果没有，
那就保留 `-1`，
表示“大小尚未给定”。
同时还会检查：
这个数必须是正数且不能为零。

```c
    // Array initialisation
  if (Token.token == T_ASSIGN) {
    if (class != C_GLOBAL)
      fatals("Variable can not be initialised", varname);
    scan(&Token);

    // Get the following left curly bracket
    match(T_LBRACE, "{");
```

目前我只处理全局数组初始化。

```c
#define TABLE_INCREMENT 10

    // If the array already has nelems, allocate that many elements
    // in the list. Otherwise, start with TABLE_INCREMENT.
    if (nelems != -1)
      maxelems= nelems;
    else
      maxelems= TABLE_INCREMENT;
    initlist= (int *)malloc(maxelems *sizeof(int));
```

这里先创建一份初始化列表。
如果数组本来已经给定了大小，
那就按 `nelems` 分配；
否则先分配 10 个整数的空间。

但如果数组本身没有固定大小，
那我们就没法预先知道初始化列表到底会有多长。
所以后面还得支持动态扩容。

```c
    // Loop getting a new literal value from the list
    while (1) {

      // Check we can add the next value, then parse and add it
      if (nelems != -1 && i == maxelems)
        fatal("Too many values in initialisation list");
      initlist[i++]= parse_literal(type);
      scan(&Token);
```

这里读取下一个字面量值，
并且如果数组大小是固定的，
就确保初始化值数量不会超过该大小。

```c
      // Increase the list size if the original size was
      // not set and we have hit the end of the current list
      if (nelems == -1 && i == maxelems) {
        maxelems += TABLE_INCREMENT;
        initlist= (int *)realloc(initlist, maxelems *sizeof(int));
      }
```

这就是初始化列表按需扩容的地方。

```c
      // Leave when we hit the right curly bracket
      if (Token.token == T_RBRACE) {
        scan(&Token);
        break;
      }

      // Next token must be a comma, then
      comma();
    }
```

这里负责处理结束用的右花括号，
或者值与值之间的逗号。
等跳出这个循环之后，
我们就得到了一份真正填好内容的 `initlist`。

```c
    // Zero any unused elements in the initlist.
    // Attach the list to the symbol table entry
    for (j=i; j < sym->nelems; j++) initlist[j]=0;
    if (i > nelems) nelems = i;
    sym->initlist= initlist;
  }
```

如果给出的初始化值数量
少于数组声明的目标大小，
那剩余那些还没被初始化的位置
就全部补零。
也正是在这里，
我们把初始化列表真正挂到符号表项里。

```c
  // Set the size of the array and the number of elements
  sym->nelems= nelems;
  sym->size= sym->nelems * typesize(type, ctype);
  // Generate any global space
  if (class == C_GLOBAL)
    genglobsym(sym);
  return (sym);
}
```

到这一步，
终于可以把 `nelems` 和 `size`
都写回符号表项了。
完成之后，
再调用 `genglobsym()`，
为这个数组真正生成内存空间。

## 对 `cgglobsym()` 的修改

在看某个数组初始化示例生成出来的汇编之前，
我们还得先看一眼：
`nelems` 和 `size` 的变化，
到底怎样影响了“生成变量存储空间”的那部分代码。

`genglobsym()` 是一个前端包装函数，
它内部只是简单调用 `cgglobsym()`。
下面来看 `cg.c` 中的这个函数：

```c
// Generate a global symbol but not functions
void cgglobsym(struct symtable *node) {
  int size, type;
  int initvalue;
  int i;

  if (node == NULL)
    return;
  if (node->stype == S_FUNCTION)
    return;

  // Get the size of the variable (or its elements if an array)
  // and the type of the variable
  if (node->stype == S_ARRAY) {
    size= typesize(value_at(node->type), node->ctype);
    type= value_at(node->type);
  } else {
    size = node->size;
    type= node->type;
  }
```

现在数组的 `type`
仍然被设成“底层元素类型的指针”。
这样就能支持下面这种写法：

```c
  char a[45];
  char *b;
  b= a;         // as they are of same type
```

不过从生成存储空间的角度来说，
我们真正需要知道的是“元素本身的大小”，
所以这里要通过 `value_at()` 来取出这个信息。
而对标量来说，
`size` 和 `type`
直接就保存在符号表项里。

```c
  // Generate the global identity and the label
  cgdataseg();
  fprintf(Outfile, "\t.globl\t%s\n", node->name);
  fprintf(Outfile, "%s:\n", node->name);
```

这部分和以前一样。
但后面的代码已经不同了：

```c
  // Output space for one or more elements
  for (i=0; i < node->nelems; i++) {
  
    // Get any initial value
    initvalue= 0;
    if (node->initlist != NULL)
      initvalue= node->initlist[i];
  
    // Generate the space for this type
    switch (size) {
      case 1:
        fprintf(Outfile, "\t.byte\t%d\n", initvalue);
        break;
      case 4:
        fprintf(Outfile, "\t.long\t%d\n", initvalue);
        break;
      case 8:
        // Generate the pointer to a string literal
        if (node->initlist != NULL && type== pointer_to(P_CHAR))
          fprintf(Outfile, "\t.quad\tL%d\n", initvalue);
        else
          fprintf(Outfile, "\t.quad\t%d\n", initvalue);
        break;
      default:
        for (int i = 0; i < size; i++)
        fprintf(Outfile, "\t.byte\t0\n");
    }
  }
}

```

对于每一个元素，
先从 `initlist` 里取出它的初始值；
如果没有初始化列表，
那就默认取 0。
然后根据元素大小，
输出 `.byte`、`.long` 或 `.quad`。

如果元素类型是 `char *`，
那初始化列表里保存的其实是字符串字面量的标签号，
因此这里输出的是 `"L%d"`，
而不是那个整数本身。

### 数组初始化示例

下面是一个很小的数组初始化例子：

```c
int x[4]= { 1, 4, 17 };
```

它会生成：

```
        .globl  x
x:
        .long   1
        .long   4
        .long   17
        .long   0
```

## 测试程序

我就不一一展开讲这些测试程序了，
不过 `tests/input89.c`
一直到 `tests/input99.c`
会一起检查：
编译器是否生成了合理的初始化代码，
以及是否能在不合法情况下抛出合适的 fatal 错误。

## 总结与下一步

这一部分的工作量确实不小。
正所谓三步前进，
一步后退。
不过我还是挺满意的，
因为现在的符号表设计，
比我之前那套要合理得多。

在编译器编写之旅的下一部分中，
我们会尝试把“局部变量初始化”
也加入编译器。 [下一步](../41_Local_Var_Init/Readme.md)
