# 第 29 部分：一点重构

我开始思考在编译器里实现结构体（struct）、
联合体（union）和枚举（enum）的设计时，
突然想到一个改进符号表的好主意，
于是这又顺手引出了对编译器代码的一次小型重构。
所以这一部分并没有新增功能，
但我对编译器里某些代码的状态确实更满意了一些。

如果你更关心的是我对 struct、union 和 enum 的设计想法，
那完全可以直接跳去下一部分。

## 重构符号表

当初开始写这个编译器时，
我刚刚读完
[SubC](http://www.t3x.org/subc/)
编译器的代码，
并且给它加了不少我自己的注释。
因此，
我最初的很多思路都是从那套代码里借来的。
其中之一就是：
用一个数组来充当符号表，
把全局符号放在一端，
把局部符号放在另一端。

但我们已经看到，
在处理函数原型和函数参数时，
我们必须把函数原型从符号表的全局端“复制”到局部端，
这样函数才能得到本地参数变量。
同时我们还得时刻担心：
符号表一端会不会撞上另一端。

因此，
在某个时刻，
我们应该把符号表改造成若干条单向链表（singly-linked list）：
至少需要一条全局符号链表，
以及一条局部符号链表。
等到以后实现枚举时，
我甚至可能还要再加第三条，
专门存放枚举值。

不过，
这一部分里我还没有真正去做这次重构，
因为它看起来改动会很大。
我打算等到“确实非做不可”的时候再动手。
但有一个额外变化我已经决定先做：
每个符号节点将来除了要有一个 `next` 指针，
用于串起单向链表之外，
还应该有一个 `param` 指针。
这样一来，
函数就可以有一条专门属于自己的参数链表，
我们在搜索全局符号时也就能直接跳过它。
而等我们需要把函数原型“复制”为函数参数列表时，
其实只需要复制这根参数链表指针就够了。
总之，
这属于将来的事情。

## 类型，再看一遍

我从 SubC 那里借来的另一个设计，
是类型枚举方式（在 `defs.h` 中）：

```c
// Primitive types
enum {
  P_NONE, P_VOID, P_CHAR, P_INT, P_LONG,
  P_VOIDPTR, P_CHARPTR, P_INTPTR, P_LONGPTR
};
```

SubC 只允许一级间接寻址，
所以它才会有上面这份类型列表。
后来我想到：
为什么不把“间接层级”直接编码进基本类型值本身呢？
于是我把代码改成：
在一个 `type` 整数值里，
低四位表示间接层级，
高位则表示真正的基础类型：

```c
// Primitive types. The bottom 4 bits is an integer
// value that represents the level of indirection,
// e.g. 0= no pointer, 1= pointer, 2= pointer pointer etc.
enum {
  P_NONE, P_VOID=16, P_CHAR=32, P_INT=48, P_LONG=64
};
```

这样一来，
旧代码里所有原先的 `P_XXXPTR` 引用，
我现在都能完全重构掉了。
我们来看看具体发生了哪些变化。

首先，
在 `types.c` 里，
我们得能处理“标量类型”和“指针类型”。
现在的代码其实比以前更短了：

```c
// Return true if a type is an int type
// of any size, false otherwise
int inttype(int type) {
  return ((type & 0xf) == 0);
}

// Return true if a type is of pointer type
int ptrtype(int type) {
  return ((type & 0xf) != 0);
}

// Given a primitive type, return
// the type which is a pointer to it
int pointer_to(int type) {
  if ((type & 0xf) == 0xf)
    fatald("Unrecognised in pointer_to: type", type);
  return (type + 1);
}

// Given a primitive pointer type, return
// the type which it points to
int value_at(int type) {
  if ((type & 0xf) == 0x0)
    fatald("Unrecognised in value_at: type", type);
  return (type - 1);
}
```

而 `modify_type()` 则完全没有变化。

在 `expr.c` 里，
处理字符串字面量时，
我原先用的是 `P_CHARPTR`；
现在就可以写成：

```c
   n = mkastleaf(A_STRLIT, pointer_to(P_CHAR), id);
```

另一个大量用到 `P_XXXPTR` 的地方，
是在平台相关代码 `cg.c` 中。
首先我们把 `cgprimsize()` 重写成基于 `ptrtype()`：

```c
// Given a P_XXX type value, return the
// size of a primitive type in bytes.
int cgprimsize(int type) {
  if (ptrtype(type)) return (8);
  switch (type) {
    case P_CHAR: return (1);
    case P_INT:  return (4);
    case P_LONG: return (8);
    default: fatald("Bad type in cgprimsize:", type);
  }
  return (0);                   // Keep -Wall happy
}
```

有了这个函数之后，
`cg.c` 里的其他代码
就可以按需调用
`cgprimsize()`、`ptrtype()`、
`inttype()`、`pointer_to()` 和 `value_at()`，
而不再去硬编码具体类型。
下面是 `cg.c` 里的一个例子：

```c
// Dereference a pointer to get the value it
// pointing at into the same register
int cgderef(int r, int type) {

  // Get the type that we are pointing to
  int newtype = value_at(type);

  // Now get the size of this type
  int size = cgprimsize(newtype);

  switch (size) {
  case 1:
    fprintf(Outfile, "\tmovzbq\t(%s), %s\n", reglist[r], reglist[r]);
    break;
  case 2:
    fprintf(Outfile, "\tmovslq\t(%s), %s\n", reglist[r], reglist[r]);
    break;
  case 4:
  case 8:
    fprintf(Outfile, "\tmovq\t(%s), %s\n", reglist[r], reglist[r]);
    break;
  default:
    fatald("Can't cgderef on type:", type);
  }
  return (r);
}
```

你可以快速翻一遍 `cg.c`，
看看所有调用 `cgprimsize()` 的地方。

### 一个双重指针的例子

既然现在我们已经支持最多十六层间接寻址，
我就顺手写了一个测试程序来确认它确实可用，
文件是 `tests/input55.c`：

```c
int printf(char *fmt);

int main(int argc, char **argv) {
  int i;
  char *argument;
  printf("Hello world\n");

  for (i=0; i < argc; i++) {
    argument= *argv; argv= argv + 1;
    printf("Argument %d is %s\n", i, argument);
  }
  return(0);
}
```

要注意的是，
`argv++` 目前还不能用，
`argv[i]` 也还不能用。
不过像上面那样稍微绕一下，
还是可以先把功能跑起来。

## 符号表结构的改动

虽然这一部分里我还没有把符号表重构成链表，
但在意识到可以使用 union，
并且甚至不需要再给 union 单独起名字之后，
我还是顺手调整了一下符号表结构本身：

```c
// Symbol table structure
struct symtable {
  char *name;                   // Name of a symbol
  int type;                     // Primitive type for the symbol
  int stype;                    // Structural type for the symbol
  int class;                    // Storage class for the symbol
  union {
    int size;                   // Number of elements in the symbol
    int endlabel;               // For functions, the end label
  };
  union {
    int nelems;                 // For functions, # of params
    int posn;                   // For locals, the negative offset
                                // from the stack base pointer
  };
};
```

我以前曾经用 `#define` 来定义 `nelems`，
但上面这种写法效果是一样的，
而且还能避免把一个全局的 `nelems` 定义污染到命名空间里。
同时我也意识到，
`size` 和 `endlabel`
在结构里完全可以共用同一个位置，
于是就给它们也加了一个 union。
`addglob()` 的参数因此有少量外观上的变动，
但除此之外并没有太多别的变化。

## AST 结构的改动

类似地，
我也把 AST 节点结构改成了“不再给 union 起变量名”的形式：

```c
// Abstract Syntax Tree structure
struct ASTnode {
  int op;                       // "Operation" to be performed on this tree
  int type;                     // Type of any expression this tree generates
  int rvalue;                   // True if the node is an rvalue
  struct ASTnode *left;         // Left, middle and right child trees
  struct ASTnode *mid;
  struct ASTnode *right;
  union {                       // For A_INTLIT, the integer value
    int intvalue;               // For A_IDENT, the symbol slot number
    int id;                     // For A_FUNCTION, the symbol slot number
    int size;                   // For A_SCALE, the size to scale by
  };                            // For A_FUNCCALL, the symbol slot number
};
```

这就意味着，
例如下面这两行里，
我现在可以写第二种形式，而不用再写第一种：

```c
    return (cgloadglob(n->left->v.id, n->op));    // Old code
    return (cgloadglob(n->left->id,   n->op));    // New code
```

## 总结与下一步

这一部分差不多就是这些内容。
我可能还顺手改了若干别的小地方，
但一时想不起还有什么值得单独拿出来讲的大改动。

把符号表改成链表这件事我迟早会做；
大概率会发生在我们实现枚举值的时候。

在编译器编写之旅的下一部分中，
我终于会回到自己原本这一部分想讲的话题：
也就是在编译器里实现 struct、union 和 enum 时的设计思路。 [下一步](../30_Design_Composites/Readme.md)
