# 第 52 部分：指针，第 2 部分

在编译器编写之旅的这一部分里，
我原本只是想修一个和指针有关的问题，
结果最后却重构了差不多一半的 `expr.c`，
还顺手改了编译器里另外四分之一函数的 API。
所以从“动到的代码行数”来说，
这是一步很大的改动；
但从“真正新增的功能和修复点”来看，
它其实并不是一次特别大的飞跃。

## 问题是什么

先从引发这一切的问题说起。
当我让编译器拿自己的源码来编译自己时，
我发现它没法解析一串连续的指针访问，
例如这样的表达式：

```c
  ptr->next->next->next
```

原因在于：
`primary()` 会先被调用，
拿到表达式开头那个标识符的值。
如果后面跟着某个后缀运算符，
它再调用 `postfix()` 去处理。
而 `postfix()` 目前只会处理一次 `->` 运算符，
然后就返回。
事情到此为止。
也就是说，
这里根本没有循环来继续吃掉后面那一串 `->`。

更糟的是，
`primary()` 自己只会查找一个单独的标识符。
这意味着，
下面这些表达式它也同样解析不了：

```c
  ptrarray[4]->next     OR
  unionvar.member->next
```

因为在 `->` 之前，
这两者都不是“单个标识符”。

## 这事为什么会发生？

这是快速原型开发模式的自然结果。
我通常都是一次只加一个很小的功能点，
也不会特别往前看太远，
去预判未来会用到什么。
所以时不时地，
我们就不得不把之前写过的东西拆掉重来，
让它变得更一般化、更灵活。

## 那该怎么修？

如果我们去看
[C 的 BNF 语法](https://www.lysator.liu.se/c/ANSI-C-grammar-y.html)，
会看到这样：

```
primary_expression
        : IDENTIFIER
        | CONSTANT
        | STRING_LITERAL
        | '(' expression ')'
        ;

postfix_expression
        : primary_expression
        | postfix_expression '[' expression ']'
        | postfix_expression '(' ')'
        | postfix_expression '(' argument_expression_list ')'
        | postfix_expression '.' IDENTIFIER
        | postfix_expression '->' IDENTIFIER
        | postfix_expression '++'
        | postfix_expression '--'
        ;
```

换句话说，
我们现在的方向正好搞反了。
应该是 `postfix()`
先去调用 `primary()`，
拿到一个能表示基础标识符的 AST 节点。
然后它再进入循环，
不断查看后面是否还跟着后缀运算符；
如果有，
就继续解析，
并在先前那个节点之上再包一层新的 AST 父节点。

这套思路听起来挺直观，
但麻烦在于：
当前的 `primary()`
其实根本不构建 AST 节点。
它只负责把标识符解析出来，
并把名字留在全局 `Text` 变量里。
真正负责为“标识符 + 后缀操作”
构建 AST 的，
一直都是 `postfix()`。

与此同时，
`defs.h` 里的 AST 节点结构
目前也只保存了“基本类型（primitive type）”：

```c
// Abstract Syntax Tree structure
struct ASTnode {
  int op;           // "Operation" to be performed on this tree
  int type;         // Type of any expression this tree generates
  int rvalue;       // NOTE: no ctype
  ...
};
```

之所以会这样，
是因为 struct 和 union
这些能力其实也是最近才加进来的。
再加上此前绝大部分解析工作
都堆在 `postfix()` 里，
所以我们一直都还没有真正需要
把“某个标识符若是 struct/union，它对应哪一个复合类型符号”
也存进 AST 节点里。

因此，
要真正修好这件事，
我们需要：

  1. 在 `struct ASTnode` 中加入一个 `ctype` 指针，
     这样每个 AST 节点都能保存完整类型信息。
  2. 找出所有构造 AST 节点的函数，
     以及所有调用这些函数的地方，
     并修好它们，
     确保 `ctype` 会被正确传入和保存。
  3. 把 `primary()` 挪到 `expr.c` 更靠前的位置，
     并让它开始真正构建 AST 节点。
  4. 让 `postfix()` 调用 `primary()`，
     拿到一个不带修饰的标识符 AST 节点
     （也就是 `A_IDENT`）。
  5. 让 `postfix()` 在存在后缀运算符时持续循环处理。

这工作量很大，
而且 AST 节点构造调用散落在整个编译器里，
所以几乎每一个源文件都得碰一遍。
真是烦人。
     
## 对 AST 节点函数的修改

我就不把所有细节一条条展开了，
先从 `defs.h` 中 AST 节点结构的修改，
以及 `tree.c` 中那个最核心的“构造 AST 节点”函数说起：

```c
// Abstract Syntax Tree structure
struct ASTnode {
  int op;                       // "Operation" to be performed on this tree
  int type;                     // Type of any expression this tree generates
  struct symtable *ctype;       // If struct/union, ptr to that type
  ...
};

// Build and return a generic AST node
struct ASTnode *mkastnode(int op, int type,
                          struct symtable *ctype, ...) {
  ...
  // Copy in the field values and return it
  n->op = op;
  n->type = type;
  n->ctype = ctype;
  ...
}
```

`mkastleaf()` 和 `mkastunary()`
也做了同样方向的修改：
它们现在也会接收一个 `ctype`，
并在内部把它传给 `mkastnode()`。

整个编译器里，
对这三个函数的调用大约有 40 处。
我当然不会把每一处都拿出来讲。
大多数情况下，
我们手头本来就同时有 primitive `type`
和对应的 `ctype` 指针。
有些调用会把 AST 节点类型设成 `P_INT`，
那么此时 `ctype` 就是 `NULL`。
还有些调用会把类型设成 `P_NONE`，
那 `ctype` 也一样还是 `NULL`。

## 对 `modify_type()` 的修改

`modify_type()`
负责判断某棵 AST 的类型
和另一种类型是否兼容，
必要时还会把前者扩宽成后者。
而它内部会调用 `mkastunary()`，
所以现在同样也得把 `ctype`
传进去。

我已经把这部分补好了。
于是相应地，
那 6 处调用 `modify_type()`
的地方也都得修改，
把它们比较目标类型对应的 `ctype`
一起传下来。

## 对 `expr.c` 的修改

现在终于来到真正的重点：
`primary()` 和 `postfix()`
的重构。
前面我已经概括过我们想做的方向了。
和之前很多改动一样，
这里中途还是有些小弯需要慢慢抹平。

## 对 `postfix()` 的修改

`postfix()` 现在看起来其实整洁多了：

```c
// Parse a postfix expression and return
// an AST node representing it. The
// identifier is already in Text.
static struct ASTnode *postfix(void) {
  struct ASTnode *n;

  // Get the primary expression
  n = primary();

  // Loop until there are no more postfix operators
  while (1) {
    switch (Token.token) {
    ...
```

它现在会先调用 `primary()`，
拿到一个基础表达式对应的 AST。
然后只要后面还跟着后缀运算符，
就继续循环处理。

我们同时还会检查：
从 `primary()` 拿回来的 AST
必须是左值而不是右值，
因为如果要做自增或自减，
我们必须拿到的是内存地址，
而不只是一个纯右值结果。

## 新函数：`paren_expression()`

我后来发现，
新的 `primary()`
已经开始膨胀得有点过头了，
所以我又把它的一部分逻辑拆成了一个新函数：
`paren_expression()`。
它负责解析被 `(..)` 包起来的表达式，
包括 cast 和普通括号表达式。

这段代码和旧逻辑基本一致，
所以我就不在这里细讲了。
它会返回一棵 AST，
表示“一个 cast 表达式”
或者“一个普通括号表达式”。

## 对 `primary()` 的修改

这里才是变化最大的一块。
先列一下它现在会处理哪些 token：

 + `static`、`extern`
   如果在这里看到它们就会直接报错，
   因为这说明我们本来应该是在局部上下文里解析表达式。
 + `sizeof()`
 + 整数字面量和字符串字面量
 + 标识符：
   这部分最大，
   因为它可能是已知类型名（如 `int`）、
   enum 名称、
   typedef 名称、
   函数名、
   数组名，
   以及 / 或者标量变量名。
   回头想想，
   我也许应该把这一大块再拆成一个单独函数。
 + `(..)`，
   也就是这里会调用 `paren_expression()`

从代码上看，
`primary()` 现在会为上面这些情况
直接构建 AST 节点，
然后再返回给 `postfix()`。
这些事情以前其实都是 `postfix()`
在做，
但现在我把它们前移到了 `primary()`。

## 对 `member_access()` 的修改

在旧版 `member_access()` 中，
全局 `Text` 变量里仍然保存着标识符名字，
而 `member_access()`
会自己去构造那个表示
struct/union 标识符的 AST 节点。

但在现在的版本里，
我们传给 `member_access()`
的已经是一棵 AST 节点。
而这个节点本身，
既可能是一个数组元素，
也可能是另一个 struct/union 的成员。

因此这里的代码也相应变了：
我们不再负责为“最初那个标识符”
创建叶子 AST 节点。
我们现在仍然会构建新的 AST 节点，
用来在基址上叠加成员偏移，
再对成员指针进行解引用。

还有一处值得注意的不同是这段代码：

```c
  // Check that the left AST tree is a struct or union.
  // If so, change it from an A_IDENT to an A_ADDR so that
  // we get the base address, not the value at this address.
  if (!withpointer) {
    if (left->type == P_STRUCT || left->type == P_UNION)
      left->op = A_ADDR;
    else
      fatal("Expression is not a struct/union");
  }
```

考虑表达式 `foo.bar`。
这里 `foo`
例如可能是一个 struct 变量，
而 `bar` 则是该 struct 的某个成员。

在 `primary()` 里，
我们一开始只能为 `foo`
构建一个 `A_IDENT` AST 节点，
因为当时还没法立刻判断它到底是普通标量变量
（例如 `int foo`）
还是结构体变量
（例如 `struct fred foo`）。

但一旦来到这里，
我们已经知道它确实是一个 struct 或 union，
于是我们真正需要的就不再是“该地址处的值”，
而是“这个 struct 的基地址”。
因此这里会把原来的 `A_IDENT`
就地改写成 `A_ADDR`。

## 测试代码

我感觉自己大概花了两个小时，
一路跑我们那一百多个回归测试，
不断发现遗漏，
再不断把它们补上。
不过最终能再次把整套测试全跑通，
还是挺舒服的。

`tests/input128.c`
现在会检查：
我们终于能跟随一串连续的指针访问了，
这也正是我这次折腾的起点：

```c
struct foo {
  int val;
  struct foo *next;
};

struct foo head, mid, tail;

int main() {
  struct foo *ptr;
  tail.val= 20; tail.next= NULL;
  mid.val= 15; mid.next= &tail;
  head.val= 10; head.next= &mid;

  ptr= &head;
  printf("%d %d\n", head.val, ptr->val);
  printf("%d %d\n", mid.val, ptr->next->val);
  printf("%d %d\n", tail.val, ptr->next->next->val);
  return(0);
}
```

而 `tests/input129.c`
则检查不能连续做两次后置自增。

## 另外一个改动：`Linestart`

为了让编译器进一步走向自举，
我在这次还顺手改了另外一件事。

原本扫描器会在看到 `'#'` token 时，
直接假设：
这是某一行 C 预处理器输出，
于是就按预处理器行去解析。
但问题是，
我之前根本没有把它限定在“每行第一列”。
所以当编译器碰到下面这行源码时：

```c
  while (c == '#') {
```

它居然会因为后面的 `')' '{'`
不像一条真正的 C 预处理器行
而当场犯病。

现在我们引入了一个 `Linestart` 变量，
用来标记扫描器当前是否位于某一新行的第一列。
改动最多的主函数是 `scan.c`
里的 `next()`。
说实话，
我觉得这次改法看起来有点丑，
但它确实能工作。
我以后应该回来再看看，
能不能把这块整理得更干净一点。

总之，
现在只有当 `'#'`
出现在第 1 列时，
我们才会把它当成 C 预处理器行。


## 总结与下一步

在编译器编写之旅的下一部分中，
我会继续把编译器源码喂给它自己，
看看还会冒出什么错误，
然后挑其中一个或几个继续修。 [下一步](../53_Mop_up_pt2/Readme.md)
