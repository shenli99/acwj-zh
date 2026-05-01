# 第 51 部分：数组，第 2 部分

在上一部分的编译器编写之旅里，
我意识到：
自己对数组的实现并不完全正确。
所以这一部分里，
我打算把这件事尽量纠正一下。

一开始，
我先退后一步，
重新想了想数组和指针的关系。
后来我意识到，
数组和指针很相似，
但仍然有下面几个关键区别：

  1. 你不能把“裸数组标识符”直接当作右值随便使用。
  2. 数组的大小是它所有元素大小的总和。
     而指针的大小并不包含它所指向数组的那些元素。
  3. 对数组取地址
     （例如 `&ary`）
     并没有什么真正有用的意义，
     这点和对指针取地址
     （例如 `&ptr`）
     不一样。

关于第一点，
来看个例子：

```c
int ary[5];
int *ptr;

int main() {
   ptr= ary;            // OK, put base address of ary into ptr
   ary= ptr;            // Bad, can't change ary's base address
```

当然，
如果这里有 C 语言洁癖患者，
我知道你会说：
第三点其实并不完全正确。
但我自己不会在任何地方用到 `&ary`，
所以我完全可以让编译器直接拒绝它。
这样一来，
我也就不必去实现这部分功能。

所以，
我们到底需要改些什么？

 + 在 `'['` 前面允许出现标量标识符或数组标识符
 + 允许裸数组标识符出现，但要把它标记成右值
 + 当我们对数组做一些不该做的事时，再补几种错误提示

差不多就这些。
我已经按这个方向改了编译器。
希望它已经覆盖了所有数组相关问题，
不过也很可能还有别的遗漏。
如果真有，
那后面我们再回来继续修。

## 对 `postfix()` 的修改

上一部分里，
我在 `expr.c` 的 `postfix()`
里先加了一个“创可贴式”的修复，
但现在该回头把它真正修干净了。
我们需要允许裸数组标识符出现，
但同时把它们标记成右值。
改动如下：

```c
static struct ASTnode *postfix(void) {
  ...
  int rvalue=0;
  ...
  // An identifier, check that it exists. For arrays, set rvalue to 1.
  if ((varptr = findsymbol(Text)) == NULL)
    fatals("Unknown variable", Text);
  switch(varptr->stype) {
    case S_VARIABLE: break;
    case S_ARRAY: rvalue= 1; break;
    default: fatals("Identifier not a scalar or array variable", Text);
  }

  switch (Token.token) {
    // Post-increment: skip over the token. Also same for post-decrement
  case T_INC:
    if (rvalue == 1)
      fatals("Cannot ++ on rvalue", Text);
  ...
    // Just a variable reference. Ensure any arrays
    // cannot be treated as lvalues.
  default:
    if (varptr->stype == S_ARRAY) {
      n = mkastleaf(A_ADDR, varptr->type, varptr, 0);
      n->rvalue = rvalue;
    } else
      n = mkastleaf(A_IDENT, varptr->type, varptr, 0);
  }
  return (n);
}
```

现在，
无论是标量变量还是数组变量，
都可以以“裸标识符”形式出现。
但数组不能作为左值使用。
同时，
数组也不允许做前置或后置自增。

换句话说，
这里要么加载数组基址的地址，
要么加载标量变量本身的值。

## 对 `array_access()` 的修改

接下来我们还得修改 `expr.c`
里的 `array_access()`，
让指针同样也能配合 `'[' ']'`
来做下标访问。
改动如下：

```c
static struct ASTnode *array_access(void) {
  struct ASTnode *left, *right;
  struct symtable *aryptr;

  // Check that the identifier has been defined as an array or a pointer.
  if ((aryptr = findsymbol(Text)) == NULL)
    fatals("Undeclared variable", Text);
  if (aryptr->stype != S_ARRAY &&
        (aryptr->stype == S_VARIABLE && !ptrtype(aryptr->type)))
    fatals("Not an array or pointer", Text);
  
  // Make a leaf node for it that points at the base of
  // the array, or loads the pointer's value as an rvalue
  if (aryptr->stype == S_ARRAY)
    left = mkastleaf(A_ADDR, aryptr->type, aryptr, 0);
  else {
    left = mkastleaf(A_IDENT, aryptr->type, aryptr, 0);
    left->rvalue= 1;
  }
  ...
}
```

现在，
我们会先确认：
这个符号确实存在，
而且它要么是一个数组，
要么是一个“指针类型的标量变量”。
确认无误之后，
如果它是数组，
就加载数组基址的地址；
如果它是指针变量，
那就加载这个指针变量里保存的值，
并把它视作右值。

## 测试这些代码改动

我就不把所有测试逐个展开了，
直接概括一下：

 + `tests/input124.c` 检查不能对数组做 `ary++`。
 + `tests/input125.c` 检查我们可以写 `ptr= ary`，然后通过指针访问数组。
 + `tests/input126.c` 检查不能写 `&ary`。
 + `tests/input127.c` 检查可以用 `fred(ary)` 把数组传给函数，并在函数里把它作为指针参数接收。


## 总结与下一步

原本我还挺担心：
为了让数组行为正确，
是不是得把整大坨代码都重写掉。
结果回头看，
其实原先的实现已经很接近了，
只是还需要再补上几处调整，
把我们真正需要的功能覆盖完整。

在编译器编写之旅的下一部分中，
我们会回到继续收尾清扫。 [下一步](../52_Pointers_pt2/Readme.md)
