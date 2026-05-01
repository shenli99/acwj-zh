# 第 39 部分：变量初始化，第 1 部分

我们现在的语言已经支持变量声明，
但还不能在声明的同时完成初始化。
所以在这一部分
（以及接下来的几部分）
里，
我会着手修掉这个问题。

在真正动手实现之前，
现在先把这件事想清楚是值得的，
因为如果顺利的话，
我也许能设计出一些可以复用的代码。
所以下面我可能会来一段有点“脑内倾倒（brain dump）”式的整理，
帮助自己把问题理顺。

现在，
我们的编译器允许在三个地方声明变量：

  + 全局变量：声明在任何函数之外
  + 函数参数：声明在参数列表里
  + 局部变量：声明在函数内部

每一种声明都包含：
变量类型描述，以及变量名。

如果从初始化的角度看：

  + 函数参数不需要初始化，因为它们的值会从调用者传入的实参中拷贝进来。
  + 全局变量不能用表达式初始化，因为没有任何函数上下文可以运行那段表达式对应的汇编代码。
  + 局部变量则可以用表达式初始化。

我们还希望在类型定义后面
能够跟上一串变量名列表。
这意味着，
这里面既有一些共通点，
也有一些必须区分处理的地方。
用一种半 BNF 的写法来说：

```
global_declaration: type_definition global_var_list ';' ;

global_var_list: global_var
               | global_var ',' global_var_list  ;

global_var: variable_name
          | variable_name '=' literal_value ;

local_declaration: type_definition local_var_list ';' ;

local_var_list: local_var
              | local_var ',' local_var_list  ;

local_var: variable_name
         | variable_name '=' expression ;

parameter_list: parameter
              | parameter ',' parameter_list ;

parameter: type_definition variable_name ;
```

下面是一些
我 *确实* 想让编译器支持的例子。

### 全局声明

```c
  int   x= 5;
  int   a, b= 7, c, d= 6;
  char *e, f;                           // e is a pointer, f isn't!
  char  g[]= "Hello", *h= "foo";
  int   j[]= { 1, 2, 3, 4, 5 };
  char *k[]= { "fish", "cat", "ball" };
  int   l[70];
```

我特意加上的那条注释，
其实影响很深。
我们必须先解析前面的基础类型，
然后对后面 *每一个* 变量，
再分别解析它前面的 `'*'`
以及后面的 `[ ]`，
这样才能判断它到底是指针还是数组。

至于初始化值列表，
我目前只打算支持像上面例子那样的一维初始化列表。

### 局部声明

上面那些例子对局部声明同样适用，
但除此之外，
我们还应该能支持下面这些局部变量声明：

```c
  int u= x + 3;
  char *v= k[0];
  char *w= k[b-6];
  int y= 2*b+c, z= l[d] + j[2*x+5];
```

我本来还打算进一步支持这样的东西：
`int list[]= { x+2, a+b, c*d, u+j[3], j[x] + j[a] };`
但光看就已经像一场灾难，
所以我觉得还是收手比较好：
要么只支持字面量值列表，
要么干脆在局部作用域里暂时不支持数组初始化。

## 现在怎么办？

老实说，
看到上面这些例子之后，
我现在多少有点害怕！
我觉得全局变量初始化应该还是能做出来，
但我必须先重写“变量列表中每个独立变量的类型解析方式”。
完成这一步之后，
我才能继续去解析 `'='`。

如果当前是在全局作用域里，
我会调用某个函数去解析字面量值。

如果是在局部作用域里，
那就不能直接拿现有的 `binexpr()` 来用，
因为它会在内部自己解析左边的变量名，
并构造出一个 lvalue AST 节点。
也许我可以手工把这个 lvalue AST 节点先搭好，
然后把它的指针传给 `binexpr()`。
接着再在 `binexpr()` 里加上这样一段逻辑：

```
  if we got an lvalue pointer {
    set left to this pointer
  } else {
    left = prefix();
    deal with the operator token
  }
  rest of the existing code
```

好吧，
现在我算是有了一个大概的计划。
我会先做一些重构。
而第一步任务就是：
重新整理“类型与变量名”的解析方式，
好让我们能够解析变量列表。

## 看看这次重构

所以我刚刚已经把代码重构完了。
乍看之下好像只是把代码重新搬了搬位置，
但也不完全是这么回事。
因此我打算先给你看一下：
新 `decl.c` 里这些函数之间是怎么相互调用的，
然后再分别说明它们各自负责什么。

我给新的 `decl.c` 画了一张调用图：

![](Figs/decl_call_graph.png)

最上面，
`global_declarations()` 负责解析所有全局内容。
它本身只是循环调用 `declaration_list()`。
另一条路径是：
当我们已经在某个函数内部，
并且读到了一个类型 token
（例如 `int`、`char` 等）时，
也会调用 `declaration_list()`
去解析接下来的变量声明。

`declaration_list()` 是新增的。
它会先调用 `parse_type()`
拿到类型信息
（例如 `int`、`char`、某个 struct、union、typedef 等）。
这个类型是整个列表的 *基础类型（base type）*，
但列表中的每个独立声明
都可能在此基础上再做修饰。
例如：

```c
  int a, *b, c[40], *d[100];
```

因此在 `declaration_list()` 中，
我们会对列表里的每个声明逐一循环。
对每个声明来说，
先调用 `parse_stars()`
看看基础类型被怎样修改了。
然后再去解析该声明各自的标识符，
这一步由 `symbol_declaration()` 负责。
接着根据后面跟着的 token，
去分别调用：

  + `function_declaration()` 处理函数，
  + `array_declaration` 处理数组，或
  + `scalar_delaration` 处理标量变量

函数声明里当然还会有参数，
所以这里又会调用 `parameter_declaration_list()`。
而参数列表本身其实也是一种声明列表，
所以最后还是会再次回到 `declaration_list()` 去处理！

图左侧的 `parse_type()`
负责读取普通类型，
例如 `int` 和 `char`；
当然，
struct、union、enum、typedef 这些类型
也都是在这里被解析的。

在 `typedef_declaration()` 中解析 typedef
理论上应该比较简单，
因为它只是给一个已存在的类型起别名。
不过我们同样还能写出这样的代码：

```c
typedef char * charptr;
```

由于 `parse_type()` 本身并不处理 `'*'` token，
所以 `typedef_declaration()`
必须手工调用 `parse_stars()`，
看看基础类型是如何被修改的，
然后再创建这个别名。

任何 enum 声明
都会交给 `enum_declaration` 处理。
而 struct 和 union
则会交给 `composite_declaration()`。
然后你猜怎么着？
一个新 struct 或 union 内部的成员，
本身又会形成一串成员声明列表，
于是我们还是会调用 `declaration_list()` 去解析它们！

## 回归测试

我现在是真的很庆幸，
自己已经积累了大约八十个独立测试。
因为如果没有这些测试，
我根本不敢放心去重构 `decl.c`。
有了它们，
我至少可以确认：
新代码在重构之后，
依然会像以前一样生成相同的错误信息，
或者生成相同的汇编输出。

## 新功能

虽然这一部分的旅程
主要还是为了给变量初始化做准备而进行的一次重新设计，
但现在我们已经支持
在全局变量和局部变量声明中使用“变量列表”了。
因此我也新增了几个测试：

```c
// tests/input84.c, locals
int main() {
  int x, y;
  x=2; y=3;
  ..
}

//input88.c, globals
struct foo {
  int x;
  int y;
} fred, mary;
```

## 总结与下一步

现在编译器已经能解析
一串跟在类型后面的变量列表了，
比如 `int a, *b, **c;`，
这让我安心不少。
我也已经在代码里留下了注释，
标明后面该把“和声明绑定在一起的赋值功能”
写到哪里去。

在编译器编写之旅的下一部分中，
我们会尝试把“带赋值的全局变量声明”
加入编译器。 [下一步](../40_Var_Initialisation_pt2/Readme.md)
