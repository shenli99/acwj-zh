# 第 34 部分：枚举与 typedef

我决定在这一部分里同时实现 enum 和 typedef，
因为它们各自都不算大。

关于 enum 的设计问题，
我们其实在第 30 部分已经讨论过了。
简单回顾一下：
enum 本质上就是“具名整数字面量”。
这里面主要有两个问题需要处理：

 + 我们不能重新定义一个 enum 类型名
 + 我们不能重新定义一个具名 enum 值

例如下面这些情况：

```c
enum fred { x, y, z };
enum fred { a, b };             // fred is redefined
enum jane { x, y };             // x and y are redefined
```

从上面的例子也能看出来，
一个枚举值列表里只有标识符名字，
并没有类型信息；
这就意味着我们没法复用现有的“变量声明解析”代码，
这里必须单独写一套解析逻辑。

## 新关键字与 token

我在语法中新增了两个关键字：`enum` 和 `typedef`，
同时也加入了两个 token：`T_ENUM` 和 `T_TYPEDEF`。
具体细节你可以直接去看 `scan.c` 中的实现。

## 用于 enum 和 typedef 的符号链表

我们需要记录声明出来的 enum 与 typedef 信息，
因此在 `data.h` 中又新增了两条符号链表：

```c
extern_ struct symtable *Enumhead,  *Enumtail;    // List of enum types and values
extern_ struct symtable *Typehead,  *Typetail;    // List of typedefs
```

在 `sym.c` 里也配套加入了函数，
用于向这些链表里添加条目，
以及按名称搜索条目。
这些链表里的节点会被标记为下面几种 class
（定义于 `defs.h`）：

```c
  C_ENUMTYPE,                   // A named enumeration type
  C_ENUMVAL,                    // A named enumeration value
  C_TYPEDEF                     // A named typedef
```

也就是说，
我们有两条链表，
但却有三种节点 class，
为什么？
原因在于：
枚举值
（例如前面例子中的 `x` 和 `y`）
其实并不真正“隶属于某一个 enum 类型”。
而 enum 类型名
（例如前面的 `fred` 和 `jane`）
本身其实也不参与太多事情，
只是我们确实必须防止它们被重复定义。

我的做法是：
在同一条 enum 符号链表里同时保存 `C_ENUMTYPE` 和 `C_ENUMVAL`。
仍然以上面的例子来说，
我们会得到：

```
   fred           x            y            z
C_ENUMTYPE -> C_ENUMVAL -> C_ENUMVAL -> C_ENUMVAL
                  0            1            2
```

这也意味着：
当我们搜索这条 enum 符号链表时，
必须能区分“搜索 `C_ENUMTYPE`”
和“搜索 `C_ENUMVAL`”这两种模式。

## 解析 enum 声明

在贴代码之前，
先看几个我们需要支持的例子：

```c
enum fred { a, b, c };                  // a is 0, b is 1, c is 2
enum foo  { d=2, e=6, f };              // d is 2, e is 6, f is 7
enum bar  { g=2, h=6, i } var1;         // var1 is really an int
enum      { j, k, l }     var2;         // var2 is really an int
```

首先，
enum 解析要接到现有解析代码的哪里？
和 struct / union 一样，
它应该挂在“解析类型”的代码上，也就是 `decl.c` 里的 `parse_type()`：

```c
// Parse the current token and return
// a primitive type enum value and a pointer
// to any composite type.
// Also scan in the next token
int parse_type(struct symtable **ctype) {
  int type;
  switch (Token.token) {

      // For the following, if we have a ';' after the
      // parsing then there is no type, so return -1
      ...
    case T_ENUM:
      type = P_INT;             // Enums are really ints
      enum_declaration();
      if (Token.token == T_SEMI)
        type = -1;
      break;
  }
  ...
}
```

我顺手修改了 `parse_type()` 的返回值语义，
用来更明确地区分：
当前到底是在声明 struct、union、enum、typedef，
还是在返回一个真正可用于后续变量声明的类型。

下面分阶段看 `enum_declaration()`。

```c
// Parse an enum declaration
static void enum_declaration(void) {
  struct symtable *etype = NULL;
  char *name;
  int intval = 0;

  // Skip the enum keyword.
  scan(&Token);

  // If there's a following enum type name, get a
  // pointer to any existing enum type node.
  if (Token.token == T_IDENT) {
    etype = findenumtype(Text);
    name = strdup(Text);        // As it gets tromped soon
    scan(&Token);
  }
```

我们这里仍然只有一个全局变量 `Text`
来保存刚扫描出来的单词；
而我们又必须能够解析像 `enum foo var1` 这样的形式。
如果在读完 `foo` 后继续扫描下一个 token，
那么 `foo` 这个字符串就会丢掉。
所以我们必须先 `strdup()` 一份。

```c
  // If the next token isn't a LBRACE, check
  // that we have an enum type name, then return
  if (Token.token != T_LBRACE) {
    if (etype == NULL)
      fatals("undeclared enum type:", name);
    return;
  }
```

这时我们命中的是像 `enum foo var1` 这样的写法，
而不是 `enum foo { ...`。
因此 `foo` 必须已经是一个已知 enum 类型。
由于所有 enum 本质上都只是 `P_INT`，
而这个值已经在调用 `enum_declaration()` 的代码中设好了，
所以这里直接返回即可。

```c
  // We do have an LBRACE. Skip it
  scan(&Token);

  // If we have an enum type name, ensure that it
  // hasn't been declared before.
  if (etype != NULL)
    fatals("enum type redeclared:", etype->name);
  else
    // Build an enum type node for this identifier
    etype = addenum(name, C_ENUMTYPE, 0);
```

现在说明我们正在解析 `enum foo { ...` 这种形式，
所以必须先检查：
`foo` 是否已经被定义为某个 enum 类型名。

```c
  // Loop to get all the enum values
  while (1) {
    // Ensure we have an identifier
    // Copy it in case there's an int literal coming up
    ident();
    name = strdup(Text);

    // Ensure this enum value hasn't been declared before
    etype = findenumval(name);
    if (etype != NULL)
      fatals("enum value redeclared:", Text);
```

这里我们再次对枚举值名字做 `strdup()`。
同时也要检查：
这个枚举值标识符之前是否已经被定义过。

```c
    // If the next token is an '=', skip it and
    // get the following int literal
    if (Token.token == T_ASSIGN) {
      scan(&Token);
      if (Token.token != T_INTLIT)
        fatal("Expected int literal after '='");
      intval = Token.intvalue;
      scan(&Token);
    }
```

这也是前面必须做 `strdup()` 的原因：
扫描整数字面量会覆盖全局 `Text` 变量的内容。
这里我们读入 `=` 和整数字面量，
再把该字面量值保存到 `intval` 中。

```c
    // Build an enum value node for this identifier.
    // Increment the value for the next enum identifier.
    etype = addenum(name, C_ENUMVAL, intval++);

    // Bail out on a right curly bracket, else get a comma
    if (Token.token == T_RBRACE)
      break;
    comma();
  }
  scan(&Token);                 // Skip over the right curly bracket
}
```

到这里，
我们已经拿到了当前枚举值的名字和它对应的整数值 `intval`。
于是可以用 `addenum()` 把它加入 enum 符号链表。
同时再把 `intval` 自增，
为下一个枚举值做好准备。

## 使用枚举名

现在我们已经有了解析 enum 值列表的代码，
也会把它们的整数字面量值存进符号表。
那到底应该在什么时候、
又该怎样查出它们并使用它们呢？

答案是：
就在“表达式里本来可能会使用变量名”的地方处理。
如果发现这个标识符其实是一个枚举值名字，
那就直接把它转换成一个具有特定值的 `A_INTLIT` AST 节点。
最合适的位置是 `expr.c` 里的 `postfix()`：

```c
// Parse a postfix expression and return
// an AST node representing it. The
// identifier is already in Text.
static struct ASTnode *postfix(void) {
  struct symtable *enumptr;

  // If the identifier matches an enum value,
  // return an A_INTLIT node
  if ((enumptr = findenumval(Text)) != NULL) {
    scan(&Token);
    return (mkastleaf(A_INTLIT, P_INT, NULL, enumptr->posn));
  }
  ...
}
```

## 测试功能

这部分就完成了。
有几个测试程序会专门确认：
我们能否正确识别“重复定义的 enum 类型名或枚举值名字”；
而 `test/input63.c` 则展示了 enum 本身正常工作：

```c
int printf(char *fmt);

enum fred { apple=1, banana, carrot, pear=10, peach, mango, papaya };
enum jane { aple=1, bnana, crrot, par=10, pech, mago, paaya };

enum fred var1;
enum jane var2;
enum fred var3;

int main() {
  var1= carrot + pear + mango;
  printf("%d\n", var1);
  return(0);
```

这里会把 `carrot + pear + mango`
也就是 `3 + 10 + 12`
相加，
最终打印出 25。

## Typedef

枚举这边就算做完了。
接下来看看 typedef。
一个 typedef 声明的基本语法是：

```
typedef_declaration: 'typedef' identifier existing_type
                   | 'typedef' identifier existing_type variable_name
                   ;
```

也就是说，
一旦读到 `typedef` 关键字，
我们就可以继续解析它后面的实际类型，
并构造一个带 `C_TYPEDEF` class 的符号节点来保存名字。
这个符号节点本身就会保存“真实类型”的 `type` 和 `ctype`。

解析代码本身非常直接。
我们同样还是挂到 `decl.c` 的 `parse_type()` 中：

```c
    case T_TYPEDEF:
      type = typedef_declaration(ctype);
      if (Token.token == T_SEMI)
        type = -1;
      break;
```

下面是 `typedef_declaration()`。
注意它会把“真实的 `type` 和 `ctype`”返回出来，
因为 typedef 声明后面还可能继续跟着一个变量名。

```c
// Parse a typedef declaration and return the type
// and ctype that it represents
int typedef_declaration(struct symtable **ctype) {
  int type;

  // Skip the typedef keyword.
  scan(&Token);

  // Get the actual type following the keyword
  type = parse_type(ctype);

  // See if the typedef identifier already exists
  if (findtypedef(Text) != NULL)
    fatals("redefinition of typedef", Text);

  // It doesn't exist so add it to the typedef list
  addtypedef(Text, type, *ctype, 0, 0);
  scan(&Token);
  return (type);
}
```

这段代码本身很直白，
不过要注意：
这里又递归调用了一次 `parse_type()`，
因为我们本来就已经有了“解析 typedef 名字后面那个真实类型”的代码。

## 查找并使用 typedef 定义

现在我们已经有了一条专门保存 typedef 定义的符号链表。
那这些定义到底怎么用？
本质上说，
我们相当于给语法再增加了一批“新的类型关键字”，
例如：

```c
FILE    *zin;
int32_t cost;
```

这意味着：
当我们在解析类型时，
如果碰到了一个自己原本并不认识的“关键字”，
那就可以顺手去 typedef 链表里查一查。
于是 `parse_type()` 再次被修改：

```c
    case T_IDENT:
      type = type_of_typedef(Text, ctype);
      break;
```

而 `type_of_typedef()` 会把 `type` 和 `ctype` 一并返回：

```c
// Given a typedef name, return the type it represents
int type_of_typedef(char *name, struct symtable **ctype) {
  struct symtable *t;

  // Look up the typedef in the list
  t = findtypedef(name);
  if (t == NULL)
    fatals("unknown type", name);
  scan(&Token);
  *ctype = t->ctype;
  return (t->type);
}
```

不过要注意，
目前我还没有把这部分做成“递归展开 typedef 链”的形式。
例如当前代码还解析不了下面这个例子：

```c
typedef int FOO;
typedef FOO BAR;
BAR x;                  // x is of type BAR -> type FOO -> type int
```

但它已经能编译 `tests/input68.c`：

```c
int printf(char *fmt);

typedef int FOO;
FOO var1;

struct bar { int x; int y} ;
typedef struct bar BAR;
BAR var2;

int main() {
  var1= 5; printf("%d\n", var1);
  var2.x= 7; var2.y= 10; printf("%d\n", var2.x + var2.y);
  return(0);
}
```

这里既把 `int` 重命名成了 `FOO`，
也把一个 struct 重命名成了 `BAR`。

## 总结与下一步

在编译器编写之旅的这一部分里，
我们同时加入了 enum 和 typedef 支持。
两者做起来都不算难，
虽然 enum 确实逼着我们额外写了不少解析代码。
之前变量列表、struct 成员列表和 union 成员列表
都能复用一套解析逻辑，
我大概是被这种顺手的感觉给惯坏了。

而 typedef 的实现就真的非常干净直接。
我后面还需要补上“typedef 的 typedef”这一层跟随逻辑；
不过这也应该不难。

在编译器编写之旅的下一部分中，
我觉得终于该把 C 预处理器（pre-processor）拉进来了。
现在既然我们已经有了 struct、union、enum 和 typedef，
理论上就已经能写出一批头文件（header file），
来声明一些常见的 Unix/Linux 库函数。
这样一来，
我们就可以在源码里 include 它们，
并写出一些真正有用的小程序了。 [下一步](../35_Preprocessor/Readme.md)
