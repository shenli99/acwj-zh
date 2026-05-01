# 第 44 部分：常量折叠（constant folding）

在上一部分的编译器编写之旅里，
我意识到：
为了在处理全局变量声明时
能够解析表达式，
我必须给编译器加入
[常量折叠（constant folding）](https://en.wikipedia.org/wiki/Constant_folding)
这种优化。

所以这一部分里，
我先把常量折叠优化加进一般表达式；
下一部分再去重写全局变量声明的解析代码。

## 什么是常量折叠？

常量折叠是一种优化方式：
如果某个表达式的值
可以在编译期就由编译器算出来，
那就没必要再生成运行期求值代码。

例如，
我们一眼就能看出
`x= 5 + 4 * 5;`
本质上等价于
`x= 25;`。
因此编译器完全可以直接算出结果，
再只输出 `x= 25;`
对应的汇编代码。

## 那具体怎么做？

答案是：
在 AST 里寻找那些“叶子节点都是整数字面量”的子树。
如果某棵二元运算子树
两边的叶子节点都是整数字面量，
那编译器就可以直接把它算出来，
并把整棵子树替换成一个单独的整数字面量节点。

同样，
如果某棵一元运算子树
它的子节点就是一个整数字面量叶子，
那也可以直接在编译期把它算掉，
再把这棵子树替换成一个整数字面量节点。

当我们能对局部子树这么做之后，
就可以写一个函数去遍历整棵 AST，
到处寻找可以折叠的子树。
在任意节点上，
大体算法如下：

  1. 先尝试折叠并替换左子节点，也就是递归处理。
  1. 再尝试折叠并替换右子节点，也就是递归处理。
  1. 如果当前是一个带两个字面量叶子的二元操作，就折叠它。
  1. 如果当前是一个带一个字面量叶子的一元操作，也折叠它。

由于我们在过程中会直接替换子树，
这意味着优化过程会先递归处理树的边缘，
再一路回卷到树根。
举个例子：

```
     *         *        *     50
    / \       / \      / \
   +   -     10  -    10  5
  / \ / \       / \
  6 4 8 3      8   3
```

## 新文件：`opt.c`

我给编译器新建了一个源文件 `opt.c`，
并在里面重写了和
[SubC](http://www.t3x.org/subc/)
编译器相同的三个函数：
`fold2()`、`fold1()` 和 `fold()`。
原版作者是 Nils M Holm。

Nils 在这部分代码里花了很多精力
去确保计算结果在不同平台上都是正确的。
这在把编译器做成交叉编译器时尤其重要。
例如，
如果你在 64 位机器上执行常量折叠，
那整数字面量的可表示范围
就会比 32 位机器大得多。
于是某些在 64 位机器上折叠出来的结果，
由于没有发生截断，
可能会和 32 位机器真正运行时的结果不一致。

我知道这是个很重要的问题，
但目前我还是继续遵循我们的
“KISS principle”，
先把代码写简单。
等后面需要时再回来补严谨性。

## 折叠二元运算

下面是用来折叠那种
“两个子节点都是整数字面量”的二元 AST 子树的代码。
目前我只折叠了少数几种运算；
`expr.c` 里其实还有不少运算
后面都可以继续加进来。

```c
// Fold an AST tree with a binary operator
// and two A_INTLIT children. Return either 
// the original tree or a new leaf node.
static struct ASTnode *fold2(struct ASTnode *n) {
  int val, leftval, rightval;

  // Get the values from each child
  leftval = n->left->a_intvalue;
  rightval = n->right->a_intvalue;
```

另一个函数会负责调用 `fold2()`，
并保证 `n->left` 和 `n->right`
都不是 `NULL`，
而且它们确实都是 `A_INTLIT` 叶子节点。
既然现在已经拿到了两个子节点的值，
那就可以开始动手计算了。

```c
  // Perform some of the binary operations.
  // For any AST op we can't do, return
  // the original tree.
  switch (n->op) {
    case A_ADD:
      val = leftval + rightval;
      break;
    case A_SUBTRACT:
      val = leftval - rightval;
      break;
    case A_MULTIPLY:
      val = leftval * rightval;
      break;
    case A_DIVIDE:
      // Don't try to divide by zero.
      if (rightval == 0)
        return (n);
      val = leftval / rightval;
      break;
    default:
      return (n);
  }
```

这里折叠的是最常见的四则运算。
注意除法分支的特殊处理：
如果右边是零，
那就不要尝试去算，
否则编译器自己会直接崩掉。
所以我们选择保留原子树不动，
等它真正变成可执行程序之后再去崩！
当然，
这里其实完全有机会直接给一个 `fatal()`。

不管怎样，
离开这个 `switch` 之后，
我们就得到一个单独的值 `val`，
它代表了整棵子树的计算结果。
接下来就该把原子树替换掉了。

```c
  // Return a leaf node with the new value
  return (mkastleaf(A_INTLIT, n->type, NULL, val));
}
```

所以，
输入的是一棵二元 AST 子树，
输出的
（如果顺利）
就是一个新的叶子节点。

## 折叠一元运算

既然你已经看过了二元运算折叠，
那一元运算这边就应该很好理解了。
目前我只折叠了两种一元运算，
但后面还可以继续扩展。

```c
// Fold an AST tree with a unary operator
// and one INTLIT children. Return either 
// the original tree or a new leaf node.
static struct ASTnode *fold1(struct ASTnode *n) {
  int val;

  // Get the child value. Do the
  // operation if recognised.
  // Return the new leaf node.
  val = n->left->a_intvalue;
  switch (n->op) {
    case A_WIDEN:
      break;
    case A_INVERT:
      val = ~val;
      break;
    case A_LOGNOT:
      val = !val;
      break;
    default:
      return (n);
  }

  // Return a leaf node with the new value
  return (mkastleaf(A_INTLIT, n->type, NULL, val));
}
```

不过在我们的编译器里实现 `fold1()`
有一个小小的弯，
原因是 `A_WIDEN`。
来看这个 AST：

```
            A_WIDEN
                |
           A_INTLIT
               1
```

这里我们的做法是：
把 `A_WIDEN`
也当成一种一元 AST 运算，
直接把子节点里的字面量值复制出来，
然后返回一个“类型已经被扩宽”
且仍然带着同一字面量值的叶子节点。

## 递归折叠整棵 AST

现在我们已经有了两个函数，
负责处理树边缘那些可折叠的小子树。
接下来就可以写一个递归函数，
先优化边缘，
再从边缘逐步回卷到树根。

```c
// Attempt to do constant folding on
// the AST tree with the root node n
static struct ASTnode *fold(struct ASTnode *n) {

  if (n == NULL)
    return (NULL);

  // Fold on the left child, then
  // do the same on the right child
  n->left = fold(n->left);
  n->right = fold(n->right);

  // If both children are A_INTLITs, do a fold2()
  if (n->left && n->left->op == A_INTLIT) {
    if (n->right && n->right->op == A_INTLIT)
      n = fold2(n);
    else
      // If only the left is A_INTLIT, do a fold1()
      n = fold1(n);
  }

  // Return the possibly modified tree
  return (n);
}
```

第一步，
如果整棵树本身就是 `NULL`，
那就直接返回 `NULL`。
这样一来，
下面两行递归调用 `fold()`
去处理左右子节点时就安全了。
换句话说，
在继续处理当前节点之前，
我们已经先把下面的子树优化了一遍。

接着，
如果当前节点的两个子节点
都是 `A_INTLIT`，
那就调用 `fold2()`
尝试把它们折叠掉。
如果只有一个整数字面量子节点，
那就改调 `fold1()`。

无论最后是树被裁短了，
还是保持不变，
现在都可以把这棵
“可能已经修改过的树”
返回给更上一层递归。

## 一个通用优化入口函数

常量折叠只是 AST 上可能做的优化之一；
后面还会有别的优化。
因此写一个前端入口函数，
统一把所有优化应用到树上，
是很合理的。
目前它只有常量折叠：

```c
// Optimise an AST tree by
// constant folding in all sub-trees
struct ASTnode *optimise(struct ASTnode *n) {
  n = fold(n);
  return (n);
}
```

后面可以随时继续往里扩。
这个函数会在 `decl.c`
的 `function_declaration()` 中被调用。
也就是说，
当我们完成一个函数及其函数体的解析，
把 `A_FUNCTION` 节点挂到树顶之后，
就会这样做：

```c
  // Build the A_FUNCTION node which has the function's symbol pointer
  // and the compound statement sub-tree
  tree = mkastunary(A_FUNCTION, type, tree, oldfuncsym, endlabel);

  // Do optimisations on the AST tree
  tree= optimise(tree);
```

## 一个示例函数

下面这个程序 `tests/input111.c`
应该足够把折叠代码跑一遍了：

```c
#include <stdio.h>
int main() {
  int x= 2000 + 3 + 4 * 5 + 6;
  printf("%d\n", x);
  return(0);
}
```

编译器理应把这个初始化
直接替换成 `x=2029;`。
那我们执行一次
`cwj -T -S tests/input111.c`
看看：

```
$ ./cwj -T -S z.c
    A_INTLIT 2029
  A_WIDEN
  A_IDENT x
A_ASSIGN
...
$ ./cwj -o tests/input111 tests/input111.c
$ ./tests/input111
2029
```

看起来是正常工作的。
而且编译器仍然通过了此前 110 个测试，
所以至少目前它已经能完成自己的任务。

## 总结与下一步

我本来打算把优化一直留到系列末尾再讲，
但现在先看到一种优化实现，
其实也挺不错。

在编译器编写之旅的下一部分中，
我们会把当前的全局声明解析器替换掉，
改成通过 `binexpr()` 配合这套新的常量折叠代码
来求值表达式。 [下一步](../45_Globals_Again/Readme.md)
