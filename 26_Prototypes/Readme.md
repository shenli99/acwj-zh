# 第 26 部分：函数原型

在编译器编写之旅的这一部分里，
我加入了“书写函数原型（function prototype）”的能力。
在这个过程中，
我还不得不重写了一些前几部分刚写好的代码；
这点确实有点抱歉。
我之前没有把后面的需求看得足够远！

那么我们为什么需要函数原型：

 + 能够声明“没有函数体”的函数原型
 + 能够在后面再给出这个函数的完整定义
 + 把原型保存在全局符号表区域里，
   并把参数作为局部变量放进局部符号表区域
 + 能够根据之前的函数原型，
   对参数个数和参数类型做错误检查

而下面这些事，
至少现在我还不打算做：

 + `function(void)`：目前它会和 `function()` 视为相同声明
 + 只写类型不写参数名的函数声明，例如
   `function(int ,char, long);`
   因为这会让解析逻辑更复杂。
   这部分以后可以再加。

## 哪些功能需要重写

在前面最近的一部分里，
我加入了“带参数和完整函数体的函数声明”支持。
当时我们的做法是：
在解析每一个参数时，
立刻把它加入全局符号表
（作为函数原型的一部分），
同时也立刻把它加入局部符号表
（作为函数自己的参数变量）。

但现在一旦要支持函数原型，
“参数列表最终一定会变成真正函数的形参”这件事就不再成立了。
例如下面这个函数原型：

```c
  int fred(char a, int foo, long bar);
```

此时我们只能把 `fred` 当作一个函数，
并把 `a`、`foo` 和 `bar`
作为三个参数放到全局符号表里。
只有等到真正的完整函数定义出现时，
我们才能再把 `a`、`foo` 和 `bar`
放进局部符号表。

因此，
我需要把“全局符号表中的 `C_PARAM` 定义”
和“局部符号表中的 `C_PARAM` 定义”
彻底拆开。

## 新解析机制的设计

下面是我快速画出来的新函数解析机制设计，
它同时要兼顾函数原型：

```
Get the identifier and '('.
Search for the identifier in the symbol table.
If it exists, there is already a prototype: get the id position of
the function and its parammeter count.

While parsing parameters:
  - if a previous prototype, compare this param's type against the existing
    one. Update the symbol's name in case this is a full function
  - if no previous prototype, add the parameter to the symbol table

Ensure # of params matches any existing prototype.
Parse the ')'. If ';' is next, done.

If '{' is next, copy the parameter list from the global symtable to the
local sym table. Copy them in a loop so that they are put in reverse order
in the local sym table.
```

我这几小时刚刚把它做完，
下面就是对应的代码改动。

## `sym.c` 的改动

我修改了 `sym.c` 里两个函数的参数列表：

```c
int addglob(char *name, int type, int stype, int class, int endlabel, int size);
int addlocl(char *name, int type, int stype, int class, int size);
```

之前，
我们让 `addlocl()` 在遇到 `C_PARAM` 时
也顺手调用 `addglob()`，
从而把同一个参数同时放进两张表。
现在既然要把这两件事拆开处理，
那最自然的做法就是：
把符号真实的 `class` 显式传给这两个函数。

`main.c` 和 `decl.c` 里都有对它们的调用。
`main.c` 里的改动很小，
我后面主要讲 `decl.c` 那边。

一旦遇到“真正的函数定义”，
我们就需要把它的参数列表
从全局符号表复制到局部符号表。
这件事本质上还是符号表自己的职责，
所以我在 `sym.c` 里加入了这个函数：

```c
// Given a function's slot number, copy the global parameters
// from its prototype to be local parameters
void copyfuncparams(int slot) {
  int i, id = slot + 1;

  for (i = 0; i < Symtable[slot].nelems; i++, id++) {
    addlocl(Symtable[id].name, Symtable[id].type, Symtable[id].stype,
            Symtable[id].class, Symtable[id].size);
  }
}
```

## `decl.c` 的改动

编译器里几乎所有的主要改动都集中在 `decl.c`。
我们先从小改动讲起，
再一路看到最关键的部分。

### `var_declaration()`

我把 `var_declaration()` 的参数列表
也改成了和 `sym.c` 中相同的风格：

```c
void var_declaration(int type, int class) {
  ...
  addglob(Text, pointer_to(type), S_ARRAY, class, 0, Token.intvalue);
  ...
  if (addlocl(Text, type, S_VARIABLE, class, 1) == -1)
  ...
  addglob(Text, type, S_VARIABLE, class, 0, 1);
}
```

我们稍后会在 `decl.c` 里别的函数中
利用这个“把 class 传进来”的能力。

### `param_declaration()`

这一块变化很大，
因为全局符号表里可能已经有一份参数列表，
也就是之前留下来的函数原型。
如果是这样，
我们就必须把新的参数列表
与旧原型在“参数个数”和“参数类型”上逐项比对。

```c
// Parse the parameters in parentheses after the function name.
// Add them as symbols to the symbol table and return the number
// of parameters. If id is not -1, there is an existing function
// prototype, and the function has this symbol slot number.
static int param_declaration(int id) {
  int type, param_id;
  int orig_paramcnt;
  int paramcnt = 0;

  // Add 1 to id so that it's either zero (no prototype), or
  // it's the position of the zeroth existing parameter in
  // the symbol table
  param_id = id + 1;

  // Get any existing prototype parameter count
  if (param_id)
    orig_paramcnt = Symtable[id].nelems;

  // Loop until the final right parentheses
  while (Token.token != T_RPAREN) {
    // Get the type and identifier
    // and add it to the symbol table
    type = parse_type();
    ident();

    // We have an existing prototype.
    // Check that this type matches the prototype.
    if (param_id) {
      if (type != Symtable[id].type)
        fatald("Type doesn't match prototype for parameter", paramcnt + 1);
      param_id++;
    } else {
      // Add a new parameter to the new prototype
      var_declaration(type, C_PARAM);
    }
    paramcnt++;

    // Must have a ',' or ')' at this point
    switch (Token.token) {
    case T_COMMA:
      scan(&Token);
      break;
    case T_RPAREN:
      break;
    default:
      fatald("Unexpected token in parameter list", Token.token);
    }
  }

  // Check that the number of parameters in this list matches
  // any existing prototype
  if ((id != -1) && (paramcnt != orig_paramcnt))
    fatals("Parameter count mismatch for function", Symtable[id].name);

  // Return the count of parameters
  return (paramcnt);
}
```

别忘了：
第一个参数在全局符号表中的槽位，
刚好就在函数名那个符号表项之后。
传进来的 `id` 是“已有原型所在的槽位”，
如果根本没有原型则为 `-1`。

很巧的是，
我们只要给它加一，
要么得到第一个参数的槽位号，
要么就得到 `0`，
后者正好可以表示“没有已有原型”。

我们依然保持“逐个循环解析参数”的结构，
但现在里面多了一段新逻辑：
要么把当前参数与已有原型比较，
要么把它加入全局符号表里形成新的原型。

等跳出循环后，
我们还可以把当前参数列表的参数个数
和原型里记录的参数个数做比较。

说实话，
这段代码现在看起来还是有点丑。
我很确定，
如果把它晾一阵子再回来看，
我应该能看出一些可进一步重构的地方。

### `function_declaration()`

以前这个函数相对简单：
拿到函数类型和名字，
加一个全局符号，
读入参数列表，
再读入函数体，
基本就结束了。

现在，
它需要同时兼容下面两种情况：
已有函数原型，
以及第一次见到的全新函数声明。
另外，
它还必须能区分：
接下来读到的是一个只带分号的函数原型，
还是一个真的带函数体的完整定义。

我这里就不把整段代码全部贴出来了，
因为它确实长了不少。
但整体流程如下：

 + 如果函数名已经存在，
   就把它当作既有原型来处理，
   记录它的槽位和参数个数
 + 解析新的参数列表，
   并与已有原型做匹配检查
 + 如果后面跟的是 `';'`，
   那说明这只是一个原型声明，
   到这里就结束
 + 如果后面跟的是 `'{'`，
   那说明这是真正的函数定义，
   此时再把全局原型中的参数列表复制到局部符号表

其中比较重要的一点是：
当我们把参数从全局符号表复制到局部符号表时，
得按循环方式倒序复制，
这样它们才能在局部符号表里得到正确的排列顺序。

## 这次改动的效果

有了这些修改之后，
编译器现在就能处理下面这种写法：

```c
int fred(char a, int foo, long bar);
...
int fred(char a, int foo, long bar) {
  ...
}
```

也就是说，
我们可以先写函数原型，
以后再给出完整定义；
同时，
如果后面的定义在参数个数或参数类型上和原型对不上，
编译器也能及时报错。

## 总结与下一步

这一部分里最麻烦的点，
不在于“函数原型”这个语法本身有多复杂，
而在于它迫使我重新思考前几部分里
已经写好的“参数进入全局 / 局部符号表”的时机。
好在最后重构下来，
整体结构比之前更清晰了，
而且也为后面更严格的检查打好了基础。

在编译器编写之旅的下一部分中，
我准备稍微放慢一点节奏，
先回头补一补测试，
尤其是对错误分支的回归测试。 [下一步](../27_Testing_Errors/Readme.md)
