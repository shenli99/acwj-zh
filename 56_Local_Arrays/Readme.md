# 第 56 部分：局部数组

说实话，
这次还真有点出乎我意料。
把局部数组实现出来，
几乎一点都不难。
原来编译器里需要的拼图其实早就都有了，
我们只是一直没把它们真正接上线而已。

## 局部数组的解析

先从解析这边开始。
我想支持局部数组声明，
但只允许写“元素个数”，
不允许在声明时直接赋值初始化。

声明这一侧其实很简单，
只要在 `decl.c` 的 `array_declaration()`
里加上下面这些代码：

```c
  // Add this as a known array. We treat the
  // array as a pointer to its elements' type
  switch (class) {
    ...
    case C_LOCAL:
      sym = addlocl(varname, pointer_to(type), ctype, S_ARRAY, 0);
      break;
    ...
  }
```

接下来，
我们还得阻止对局部数组做初始化赋值：

```c
  // Array initialisation
  if (Token.token == T_ASSIGN) {
    if (class != C_GLOBAL && class != C_STATIC)
      fatals("Variable can not be initialised", varname);
```

我还顺手补了一些额外的错误检查：

```c
  // Set the size of the array and the number of elements
  // Only externs can have no elements.
  if (class != C_EXTERN && nelems<=0)
    fatals("Array must have non-zero elements", sym->name);
```

到这里为止，
局部数组在“声明解析”这一侧的工作就做完了。

## 代码生成

在 `cg.c` 里，
有个 `newlocaloffset()` 函数，
负责计算局部变量
相对于当前栈帧顶部的偏移量。
它原本接收的是 primitive type，
因为当时编译器只允许局部变量是 `int`
或者指针类型。

现在每个符号本身都已经带有自己的 `size`
信息了
（`sizeof()` 也是依赖这个工作的），
所以我们可以把这个函数的实现
改成直接根据符号大小来分配：

```c
// Create the position of a new local variable.
static int newlocaloffset(int size) {
  // Decrement the offset by a minimum of 4 bytes
  // and allocate on the stack
  localOffset += (size > 4) ? size : 4;
  return (-localOffset);
}
```

而在负责生成函数前导代码的
`cgfuncpreamble()` 中，
只需要做下面这些修改：

```c
  // Copy any in-register parameters to the stack, up to six of them
  // The remaining parameters are already on the stack
  for (parm = sym->member, cnt = 1; parm != NULL; parm = parm->next, cnt++) {
    if (cnt > 6) {
      parm->st_posn = paramOffset;
      paramOffset += 8;
    } else {
      parm->st_posn = newlocaloffset(parm->size);       // Here
      cgstorlocal(paramReg--, parm);
    }
  }

  // For the remainder, if they are a parameter then they are
  // already on the stack. If only a local, make a stack position.
  for (locvar = Loclhead; locvar != NULL; locvar = locvar->next) {
    locvar->st_posn = newlocaloffset(locvar->size);     // Here
  }
```

就这些，
搞定。
这甚至还暗示了一件事：
我们也许同样可以支持把 struct 和 union
作为局部变量。
我这次还没去碰这个方向，
不过以后值得继续探索。

## 测试这些修改

`test/input140.c`
里声明了：

```c
int main() {
  int  i;
  int  ary[5];
  char z;
  ...
```

这个数组会用一个 FOR 循环来填充，
其中 `i` 作为下标。
局部变量 `z`
也会被初始化。
这个测试用来检查：
这些局部变量之间
是否会互相踩坏彼此的存储空间。
同时它也验证了：
我们确实可以给数组所有元素赋值，
并且之后还能正确地把这些值读回来。

`test/input141.c`
和 `test/input142.c`
则用来检查：
编译器能否正确识别并拒绝
“数组作为参数”
以及“元素个数为零的数组声明”这两类非法情况。

## 总结与下一步

在编译器编写之旅的下一部分中，
我会回到继续做“收尾清扫（mopping up）”
这件事上。 [下一步](../57_Mop_up_pt3/Readme.md)
