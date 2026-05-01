# 第 30 部分：设计结构体、联合体与枚举

这一部分里，
我会先把自己在编译器里实现 struct、union 和 enum 的设计思路勾勒出来。
和函数支持一样，
这件事也会拆成接下来的多个步骤逐步完成。

我还决定顺手把符号表从“单个数组”改写成“若干条单向链表”。
之前我就提过自己迟早会这么做；
而当我开始思考如何实现这些复合类型（composite type）时，
这一步重写已经变得相当必要了。

在进入代码改动之前，
我们先看一下：
到底什么叫复合类型。

## 复合类型、枚举与 typedef

在 C 里，
[struct](https://en.wikipedia.org/wiki/Struct_(C_programming_language))
和 [union](https://en.wikipedia.org/wiki/Union_type#C/C++)
都被称为*复合类型（composite type）*。
一个 struct 或 union 变量内部
可以同时包含多个成员（member）。
两者的区别在于：
对于 struct，
这些成员在内存中保证不会彼此重叠；
而对于 union，
我们反而希望所有成员共享同一片内存位置。

下面是一个 struct 类型的例子：

```c
struct foo {
  int  a;
  int  b;
  char c;
};

struct foo fred;
```

变量 `fred` 的类型是 `struct foo`，
它拥有三个成员 `a`、`b` 和 `c`。
于是我们现在可以对 `fred` 做下面三次赋值：

```c
  fred.a= 4;
  fred.b= 7;
  fred.c= 'x';
```

这三个值都会分别存进 `fred` 中对应的成员里。

另一方面，
下面是一个 union 类型的例子：

```c
union bar {
  int  a;
  int  b;
  char c;
};

union bar jane;
```

如果我们执行下面这些语句：

```c
  jane.a= 5;
  printf("%d\n", jane.b);
```

那么打印出来的会是 5，
因为在 `jane` 这个 union 里，
成员 `a` 和 `b` 占据的是同一块内存位置。

### 枚举

虽然 enum 并不像 struct 和 union 那样定义一种复合类型，
但我还是打算在这里一并讲掉。
在 C 中，
[enum](https://en.wikipedia.org/wiki/Enumerated_type#C)
本质上是一种“给整型值起名字”的机制。
一个 enum 代表的是一组带名字的整数值。

例如，
我们可以这样定义一批新的标识符：

```c
enum { apple=1, banana, carrot, pear=10, peach, mango, papaya };
```

于是现在就有了这些具名整数值：

|  Name  | Value |
|:------:|:-----:|
| apple  |   1   |
| banana |   2   |
| carrot |   3   |
| pear   |  10   |
| peach  |  11   |
| mango  |  12   |
| papaya |  13   |

关于 enum，
还有一些我以前并没认真想过、但实际挺有意思的问题，
后面会专门讲。

### Typedef

这里我也顺手提一下 typedef，
虽然为了让我们的编译器能够“自举编译自己”，
暂时并不需要先把 typedef 做出来。
[typedef](https://en.wikipedia.org/wiki/Typedef)
的作用是：
给一个已经存在的类型再起一个别名。
它经常被拿来让 struct 和 union 的命名更方便。

沿用前面的例子，
我们可以写：

```c
typedef struct foo Husk;
Husk kim;
```

`kim` 的类型是 `Husk`，
这和说 `kim` 的类型是 `struct foo` 完全等价。

## 类型和符号到底是什么关系？

既然 struct、union 和 typedef 都是在引入新类型，
那它们跟“存放变量和函数定义的符号表”到底有什么关系？
而 enum 看起来更只是“给整数字面量起名字”，
也不像变量或函数。

关键在于，
这些东西全都有*名字*：
struct 或 union 本身的名字，
它们成员的名字，
成员的类型，
枚举值的名字，
以及 typedef 的名字。

我们必须把这些名字存到某个地方，
而且还要能够查回它们。
对 struct/union 成员来说，
我们需要查出其底层类型；
对枚举值名称来说，
我们需要查出它对应的整数字面量值。

这就是为什么我打算继续利用“符号表”来存这些东西。
只不过，
我们需要把这张表拆成几个更具体的链表，
这样既能更快找到想找的东西，
也能避免误命中不该找到的符号。

## 重新设计符号表结构

先从下面这些链表开始：

 + 一条用于全局变量和函数的单向链表
 + 一条用于当前函数局部变量的单向链表
 + 一条用于当前函数局部参数的单向链表

在原先基于数组的符号表里，
搜索全局变量和函数时，
我们不得不跳过函数参数。
所以现在，
还不如干脆再给函数参数单独走一条方向不同的链：

```c
struct symtable {
  char *name;                   // Name of a symbol
  int stype;                    // Structural type for the symbol
  ...
  struct symtable *next;        // Next symbol in one list
  struct symtable *member;      // First parameter of a function
};
```

我们来看一个图形化示意。
假设有下面这段代码：

```c
  int a;
  char b;
  void func1(int x, int y);
  void main(int argc, char **argv) {
    int loc1;
    int loc2;
  }
```

那么它会以三条符号表链表的形式存成这样：

![](Figs/newsymlists.png)

注意这里有三个链表“头指针”，
分别指向三条链。
这样我们遍历全局符号链表时，
就再也不需要主动跳过参数了，
因为每个函数自己的参数都放在它自己的参数链上。

等到真正开始解析某个函数体时，
我们只需要让“参数链表”指向这个函数自己的参数链。
然后随着局部变量不断声明，
它们就直接被追加到局部变量链表里。

之后，
当函数体解析完毕并且汇编代码已经生成出来时，
我们只要把“参数链表”和“局部变量链表”重新置空即可；
而对那个全局可见函数节点自己的参数链不会造成任何影响。

这就是目前我对“符号表改写”的整体进度。
不过这还没有真正解释：
struct、union 和 enum 该怎么依附到这套结构上。

## 一些有意思的问题与考虑

在真正讨论“如何扩展现有符号表节点与单向链表来支持 struct、union、enum”之前，
我们先得看看它们自身有哪些比较微妙的问题。

### 联合体

先从 union 开始。
第一，
union 可以嵌进 struct 中。
第二，
这个 union 本身甚至可以没有名字。
第三，
struct 内部也不一定要额外声明一个变量来承载这个 union。
例如：

```c
#include <stdio.h>
struct fred {
  int x;
  union {
    int a;
    int b;
  };            // No need to declare a variable of this union type
};

int main() {
  struct fred foo;
  foo.x= 5;
  foo.a= 12;                            // a is treated like a struct member
  foo.b= 13;                            // b is treated like a struct member
  printf("%d %d\n", foo.x, foo.a);      // Print 5 and 13
}
```

这类情况我们必须支持。
匿名 union（以及匿名 struct）其实不难：
只要把符号表节点中的 `name` 设成 `NULL` 即可。
但这里还存在另一个问题：
这个 union 并没有对应的变量名。
我觉得可以这样实现：
把“这个 union 作为 struct 成员时的成员名”也同样设成 `NULL`，
也就是这样：

![](Figs/structunion1.png)

### 枚举

虽然以前我用过 enum，
但我其实从来没有认真想过“它该怎么实现”。
于是我专门写了下面这个 C 程序，
想看看能不能把 enum “玩坏”：

```c
#include <stdio.h>

enum fred { bill, mary, dennis };
int fred;
int mary;
enum fred { chocolate, spinach, glue };
enum amy { garbage, dennis, flute, amy };
enum fred x;
enum { pie, piano, axe, glyph } y;

int main() {
  x= bill;
  y= pie;
  y= bill;
  x= axe;
  x= y;
  printf("%d %d %ld\n", x, y, sizeof(x));
}
```

它主要想回答这些问题：

 + 我们能不能用不同元素列表重新声明同一个枚举名，
   例如 `enum fred` 再来一个 `enum fred`？
 + 能不能声明一个和枚举列表同名的变量，
   例如 `fred`？
 + 能不能声明一个和枚举值同名的变量，
   例如 `mary`？
 + 能不能在不同的枚举列表中重用同一个枚举值名字，
   例如 `dennis` 和 `dennis`？
 + 能不能把一个枚举列表里的值赋给另一个枚举列表类型的变量？
 + 能不能在两个不同枚举类型的变量之间直接赋值？

下面是 `gcc` 给出的错误和警告：

```c
z.c:4:5: error: ‘mary’ redeclared as different kind of symbol
 int mary;
     ^~~~
z.c:2:19: note: previous definition of ‘mary’ was here
 enum fred { bill, mary, dennis };
                   ^~~~
z.c:5:6: error: nested redefinition of ‘enum fred’
 enum fred { chocolate, spinach, glue };
      ^~~~
z.c:5:6: error: redeclaration of ‘enum fred’
z.c:2:6: note: originally defined here
 enum fred { bill, mary, dennis };
      ^~~~
z.c:6:21: error: redeclaration of enumerator ‘dennis’
 enum amy { garbage, dennis, flute, amy };
                     ^~~~~~
z.c:2:25: note: previous definition of ‘dennis’ was here
 enum fred { bill, mary, dennis };
                         ^~~~~~
```

在反复修改并重新编译上面的程序几次之后，
结论如下：

 + 我们不能重新声明 `enum fred`。
   这似乎是唯一一个必须记住“枚举列表名”本身的地方。
 + 我们可以把 `fred` 这个枚举列表标识符复用成变量名。
 + 我们不能在另一个枚举列表里复用枚举值标识符 `mary`，
   也不能把它拿来当变量名。
 + 枚举值几乎可以到处赋值：
   它们看起来本质上就只是具名整数字面量。
 + 甚至好像可以把 `enum` 或 `enum X` 当类型的地方，
   直接换成 `int`。

## 设计上的考虑

好，
我觉得现在差不多可以开始列出真正需要支持的东西了：

 + 一张“具名或匿名 struct 列表”，
   其中每个 struct 还要保存自己的成员名、
   每个成员的类型信息，
   以及该成员相对于 struct 基址的内存偏移
 + union 也一样需要一张对应列表，
   只不过它们所有成员的偏移永远都是 0
 + 一张“枚举列表名与各枚举值及其整数值”的列表
 + 对于普通符号表，
   非复合类型仍然保留现有 `type` 信息；
   但如果某个符号是 struct 或 union，
   还必须额外有一个指针指向对应的复合类型定义
 + 既然 struct 可以包含“指向自身的指针成员”，
   那我们必须允许某个成员类型反过来再指回同一个 struct

## 符号表节点结构的改动

下面是我对当前“单向链表版符号表节点”的改动，
新增部分我在原文里用粗体标了出来：

<pre>
struct symtable {
  char *name;                   // Name of a symbol
  int type;                     // Primitive type for the symbol
  <b>struct symtable *ctype;       // If needed, pointer to the composite type</b>
  int stype;                    // Structural type for the symbol
  int class;                    // Storage class for the symbol
  union {
    int size;                   // Number of elements in the symbol
    int endlabel;               // For functions, the end label
    <b>int intvalue;               // For enum symbols, the associated value</b>
  };
  union {
    int nelems;                 // For functions, # of params
    int posn;                   // For locals, the negative offset
                                // from the stack base pointer
  };
  struct symtable *next;        // Next symbol in one list
  struct symtable *member;      // First member of a function, struct,
};                              // union or enum
</pre>

配合这个新的节点结构，
我们将拥有六条链表：

 + 一条用于全局变量和函数的单向链表
 + 一条用于当前函数局部变量的单向链表
 + 一条用于当前函数局部参数的单向链表
 + 一条用于已定义 struct 类型的单向链表
 + 一条用于已定义 union 类型的单向链表
 + 一条用于已定义的枚举名与枚举值的单向链表

## 新符号表节点在各场景中的用法

现在我们来看看，
上面这个结构体里的每个字段，
在前面列出的六条链表里会分别怎么用。

### 新类型

我们会新增两种类型：`P_STRUCT` 和 `P_UNION`，
后面马上会提到它们。

### 全局变量与函数、参数变量、局部变量

 + *name*：变量或函数名
 + *type*：变量类型，或者函数返回值类型，再加 4 bit 的间接层级信息
 + *ctype*：如果变量是 `P_STRUCT` 或 `P_UNION`，
   这个字段指向对应 struct/union 的定义节点
 + *stype*：变量或函数的结构类型，
   即 `S_VARIABLE`、`S_FUNCTION` 或 `S_ARRAY`
 + *class*：变量的存储类别，
   即 `C_GLOBAL`、`C_LOCAL` 或 `C_PARAM`
 + *size*：对普通变量来说是总字节大小；
   对数组来说是元素个数。
   后面实现 `sizeof()` 时会用到
 + *endlabel*：对函数来说，
   表示它的结束标签，`return` 会跳回这里
 + *nelems*：对函数来说是参数个数
 + *posn*：对局部变量和参数来说，
   是该变量相对于栈基指针的负偏移
 + *next*：此链表中的下一个符号
 + *member*：对函数来说，
   指向它第一个参数节点；变量则为 `NULL`

### Struct 类型

 + *name*：struct 类型名；如果匿名则为 `NULL`
 + *type*：永远是 `P_STRUCT`，其实不一定非要有
 + *ctype*：未使用
 + *stype*：未使用
 + *class*：未使用
 + *size*：整个 struct 的总字节大小，
   后面实现 `sizeof()` 时会用到
 + *nelems*：struct 的成员个数
 + *next*：下一个已定义的 struct 类型
 + *member*：指向该 struct 第一个成员节点

### Union 类型

 + *name*：union 类型名；如果匿名则为 `NULL`
 + *type*：永远是 `P_UNION`，其实不一定非要有
 + *ctype*：未使用
 + *stype*：未使用
 + *class*：未使用
 + *size*：整个 union 的总字节大小，
   后面实现 `sizeof()` 时会用到
 + *nelems*：union 的成员个数
 + *next*：下一个已定义的 union 类型
 + *member*：指向该 union 第一个成员节点

### Struct 与 Union 成员

每个成员本质上都很像一个变量，
因此和普通变量之间有大量相似之处。

 + *name*：成员名
 + *type*：成员类型，再加 4 bit 的间接层级信息
 + *ctype*：如果成员类型是 `P_STRUCT` 或 `P_UNION`，
   这个字段指向对应 struct/union 的定义节点
 + *stype*：成员的结构类型，
   即 `S_VARIABLE` 或 `S_ARRAY`
 + *class*：未使用
 + *size*：普通变量时是总字节大小；
   数组时是元素个数。
   后面实现 `sizeof()` 会用到
 + *posn*：成员相对于 struct/union 基址的正偏移
 + *next*：该 struct/union 中的下一个成员
 + *member*：`NULL`

### 枚举列表名与枚举值

我想把下面这些符号和隐式值都存起来：

```c
  enum fred { chocolate, spinach, glue };
  enum amy  { garbage, dennis, flute, couch };
```

一种做法当然是：
只把 `fred` 再连到 `amy`，
然后在 `fred` 的 `member` 字段里挂上
`chocolate`、`spinach`、`glue` 那条链。
`garbage` 那一组也是一样。

不过实际上，
我们真正只需要记住 `fred` 和 `amy` 这两个名字，
用来防止它们再次被复用成新的枚举列表名。
而真正重要的，
其实是各个枚举值名称以及它们对应的整数值。

因此我准备引入两个“哑类型”值：`P_ENUMLIST` 和 `P_ENUMVAL`。
然后只构建一条一维链表：

```c
     fred  -> chocolate-> spinach ->   glue  ->    amy  -> garbage -> dennis -> ...
  P_ENUMLIST  P_ENUMVAL  P_ENUMVAL  P_ENUMVAL  P_ENUMLIST  P_ENUMVAL  P_ENUMVAL
```

这样一来，
当我们要查找 `glue` 这个词时，
只需要遍历这一条链。
否则的话，
我们就得先找到 `fred`，
再遍历 `fred` 的成员链；
然后遇到 `amy` 时还得再做一次。
我觉得直接用一条链会更简单。

## 已经改动好的部分

在这篇文档最开始我提到过，
我已经把符号表从单个数组重写成了若干条单向链表，
同时在 `struct symtable` 节点里加入了这些字段：

```c
  struct symtable *next;        // Next symbol in one list
  struct symtable *member;      // First parameter of a function
```

所以接下来，
我们快速看一圈这些已经落地的改动。
先说明一下：
这里还没有任何功能层面的新增。

### 三条符号表链表

现在 `data.h` 中有三条符号表链表：

```c
// Symbol table lists
struct symtable *Globhead, *Globtail;   // Global variables and functions
struct symtable *Loclhead, *Locltail;   // Local variables
struct symtable *Parmhead, *Parmtail;   // Local parameters
```

而 `sym.c` 中所有相关函数都已经改写为使用它们。
我还写了一个通用函数，
用于把节点追加到某条链表末尾：

```c
// Append a node to the singly-linked list pointed to by head or tail
void appendsym(struct symtable **head, struct symtable **tail,
               struct symtable *node) {

  // Check for valid pointers
  if (head == NULL || tail == NULL || node == NULL)
    fatal("Either head, tail or node is NULL in appendsym");

  // Append to the list
  if (*tail) {
    (*tail)->next = node; *tail = node;
  } else *head = *tail = node;
  node->next = NULL;
}
```

现在还有一个 `newsym()` 函数，
它接收一个符号表节点所需的全部字段值，
内部通过 `malloc()` 创建新节点、
填好字段并返回。
这里我就不贴代码了。

针对每一条链表，
都还有一个函数用来创建并追加节点。
其中一个例子是：

```c
// Add a symbol to the global symbol list
struct symtable *addglob(char *name, int type, int stype, int class, int size) {
  struct symtable *sym = newsym(name, type, stype, class, size, 0);
  appendsym(&Globhead, &Globtail, sym);
  return (sym);
}
```

另外，
我还写了一个通用查找函数，
它可以在指定链表里搜索符号；
这里的 `list` 参数就是链表头：

```c
// Search for a symbol in a specific list.
// Return a pointer to the found node or NULL if not found.
static struct symtable *findsyminlist(char *s, struct symtable *list) {
  for (; list != NULL; list = list->next)
    if ((list->name != NULL) && !strcmp(s, list->name))
      return (list);
  return (NULL);
}
```

然后在它之上，
又有三个面向具体链表的 `findXXX()` 函数。

现在还有一个 `findsymbol()`，
它会先在函数参数链表里找，
再找函数局部变量，
最后才找全局变量。

此外还有一个 `findlocl()`，
它只搜索函数参数和局部变量。
我们在声明局部变量时会用它，
避免重复声明。

最后还有 `clear_symtable()`，
负责把这三条链表的头尾都重置成 `NULL`，
也就是把三条链全部清空。

### 参数链表与局部链表

全局符号链表只会在“每个源文件解析完成之后”清空一次。
但每当我们开始解析一个新函数的函数体时，
就必须：
a) 建立参数链表；
b) 清空局部变量链表。

它的工作方式如下。
当我们在 `expr.c` 的 `param_declaration()` 中解析参数列表时，
会为每个参数调用 `var_declaration()`。
这会创建一个符号表节点，
并把它追加到参数链表，
也就是 `Parmhead` / `Parmtail`。
等 `param_declaration()` 返回时，
`Parmhead` 就指向这条参数链。

回到负责解析整个函数
（函数名、参数列表以及函数体）
的 `function_declaration()` 中，
参数链会被存进该函数自己的符号节点：

```c
    newfuncsym->nelems = paramcnt;
    newfuncsym->member = Parmhead;

    // Clear out the parameter list
    Parmhead = Parmtail = NULL;
```

接着我们像上面这样，
把 `Parmhead` 和 `Parmtail` 置为 `NULL`，
相当于把“当前参数链表”清空。
这样一来，
这些参数就不再能通过全局参数链直接搜索到了。

解决办法是：
再设置一个全局变量 `Functionid`，
让它指向当前函数自己的符号表项：

```c
  Functionid = newfuncsym;
```

于是当我们调用 `compound_statement()` 去解析函数体时，
仍然可以通过 `Functionid->member`
访问到参数链表，
从而继续做下面这些事情：

 + 防止局部变量声明与参数重名
 + 像使用普通局部变量一样使用参数名

最终，
`function_declaration()` 会返回一棵覆盖整个函数的 AST，
交回给 `global_declarations()`；
随后后者再把它传给 `gen.c` 中的 `genAST()` 来生成汇编代码。
等 `genAST()` 返回之后，
`global_declarations()` 会调用 `freeloclsyms()`，
把局部变量链与参数链清空，
并把 `Functionid` 重置回 `NULL`。

### 其他值得一提的改动

说实话，
因为符号表从数组变成了多条链表，
整套代码其实有非常多地方都不得不跟着改写。
我不会把整个代码库逐个走一遍。
不过有些变化是一眼就能看出来的。
例如以前引用符号节点时，
代码常常写成 `Symtable[n->id]`；
现在则变成了 `n->sym`。

另外，
`cg.c` 中很多地方都要引用符号名，
所以你现在经常会看到 `n->sym->name` 这种写法。
同样，
`tree.c` 里打印 AST 的逻辑，
现在也到处都是 `n->sym->name`。

## 总结与下一步

这一部分里，
一半是设计，
一半是重实现。
我们花了不少时间去理清：
在实现 struct、union 和 enum 时，
会碰到哪些问题。
接着又重新设计了符号表，
使其能承载这些新概念。
最后，
我们把符号表先改写成了三条链表
（暂时先是三条），
为后续实现这些新特性做准备。

在编译器编写之旅的下一部分中，
我大概率会先实现“struct 类型声明”本身，
但还不会立刻让它们真的能被使用。
那部分我准备放到再下一篇里。
如果这两步顺利做完，
我希望第三步就能把 union 加进来；
再第四步实现 enum。走着看吧。 [下一步](../31_Struct_Declarations/Readme.md)
