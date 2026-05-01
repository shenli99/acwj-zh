# 第 32 部分：访问 struct 中的成员

这一部分的编译器编写之旅，
结果比我原先预想得简单不少。
我给语言加入了 `.` 和 `->` 两个 token，
并实现了对“全局 struct 变量的一层成员访问”。

我先把测试程序 `tests/input58.c` 放在这里，
这样你能更直观看到我实际支持了哪些语言特性：

```c
int printf(char *fmt);

struct fred {                   // Struct declaration, done last time
  int x;
  char y;
  long z;
};

struct fred var2;               // Variable declaration, done last time
struct fred *varptr;            // Pointer variable declaration, done last time

int main() {
  long result;

  var2.x= 12;   printf("%d\n", var2.x);         // Member access as lvalue, new
  var2.y= 'c';  printf("%d\n", var2.y);
  var2.z= 4005; printf("%d\n", var2.z);

  result= var2.x + var2.y + var2.z;             // Member access as rvalue, new
  printf("%d\n", result);

  varptr= &var2;                                // Old behaviour
  result= varptr->x + varptr->y + varptr->z;    // Member access through pointer, new
  printf("%d\n", result);
  return(0);
}
```

## 新 token

我们新增了两个 token：
`T_DOT` 和 `T_ARROW`，
分别对应输入里的 `.` 和 `->`。
照例，
`scan.c` 中识别它们的代码我就不贴了。

## 解析成员引用

这部分最终和我们现有的“数组元素访问”代码非常相似。
先看看两者之间的相同点和差异。
对于下面这段代码：

```c
  int x[5];
  int y;
  ...
  y= x[3];
```

我们会先取出数组 `x` 的基地址，
再把 3 乘上 `int` 类型的字节大小
（比如 3*4 得到 12），
把这个值加到基地址上，
并把结果当成“我们想访问的那个 `int` 的地址”。
然后对这个地址做解引用，
取出该数组位置上的值。

访问 struct 成员和它非常像：

```c
  struct fred { int x; char y; long z; };
  struct fred var2;
  char y;
  ...
  y= var2.y;
```

我们会先取出 `var2` 的基地址，
再取出 `fred` 这个 struct 中成员 `y` 的偏移量，
把偏移量加到基地址上，
并把结果视为“那个 `char` 成员的地址”。
然后再对这个地址做解引用，
取出该成员的值。

## 后缀运算符

`T_DOT` 和 `T_ARROW` 都是后缀运算符（postfix operator），
就像数组下标里的 `[` 一样，
它们都出现在标识符之后。
因此，
把它们的解析加进 `expr.c` 里现有的 `postfix()` 函数最合适：

```c
static struct ASTnode *postfix(void) {
  ...
    // Access into a struct or union
  if (Token.token == T_DOT)
    return (member_access(0));
  if (Token.token == T_ARROW)
    return (member_access(1));
  ...
}
```

`expr.c` 里新增的 `member_access()` 函数
会接收一个参数，
用于表示“我们现在是通过指针访问成员，
还是直接访问成员”。
下面按阶段来看这个新函数。

```c
// Parse the member reference of a struct (or union, soon)
// and return an AST tree for it. If withpointer is true,
// the access is through a pointer to the member.
static struct ASTnode *member_access(int withpointer) {
  struct ASTnode *left, *right;
  struct symtable *compvar;
  struct symtable *typeptr;
  struct symtable *m;

  // Check that the identifier has been declared as a struct (or a union, later),
  // or a struct/union pointer
  if ((compvar = findsymbol(Text)) == NULL)
    fatals("Undeclared variable", Text);
  if (withpointer && compvar->type != pointer_to(P_STRUCT))
    fatals("Undeclared variable", Text);
  if (!withpointer && compvar->type != P_STRUCT)
    fatals("Undeclared variable", Text);
```

第一步先做一些错误检查。
我知道后面还得把 union 的检查也加进去，
所以这里暂时先不着急重构得太漂亮。

```c
  // If a pointer to a struct, get the pointer's value.
  // Otherwise, make a leaf node that points at the base
  // Either way, it's an rvalue
  if (withpointer) {
    left = mkastleaf(A_IDENT, pointer_to(P_STRUCT), compvar, 0);
  } else
    left = mkastleaf(A_ADDR, compvar->type, compvar, 0);
  left->rvalue = 1;
```

在这里，
我们需要先拿到“这个复合变量的基地址”。
如果传进来的是一个指针，
那只要通过 `A_IDENT` AST 节点把这个指针值加载出来就行。
否则的话，
标识符本身就是 struct 或 union，
所以我们应该用 `A_ADDR` AST 节点取出它的地址。

注意这个节点不可能是 lvalue，
也就是说我们不可能写出 `var2. = 5` 这种东西。
它必须是 rvalue。

```c
  // Get the details of the composite type
  typeptr = compvar->ctype;

  // Skip the '.' or '->' token and get the member's name
  scan(&Token);
  ident();
```

这里我们先拿到复合类型定义节点的指针，
这样后面就可以遍历这个类型的成员链表；
然后再跳过 `.` 或 `->`，
读出后面的成员名
（并确认它确实是一个标识符）。

```c
  // Find the matching member's name in the type
  // Die if we can't find it
  for (m = typeptr->member; m != NULL; m = m->next)
    if (!strcmp(m->name, Text))
      break;

  if (m == NULL)
    fatals("No member found in struct/union: ", Text);
```

接着我们沿着成员链表查找名字匹配的那个成员。

```c
  // Build an A_INTLIT node with the offset
  right = mkastleaf(A_INTLIT, P_INT, NULL, m->posn);

  // Add the member's offset to the base of the struct and
  // dereference it. Still an lvalue at this point
  left = mkastnode(A_ADD, pointer_to(m->type), left, NULL, right, NULL, 0);
  left = mkastunary(A_DEREF, m->type, left, NULL, 0);
  return (left);
}

```

成员的字节偏移量保存在 `m->posn` 中，
所以我们先用它构造一个 `A_INTLIT` 节点；
再把这个偏移量加到 `left` 中保存的基地址上。
到这一步为止，
我们就已经得到了该成员的地址，
所以接下来再做一次解引用（`A_DEREF`），
就能真正访问到这个成员的值了。
而且此时它依然还是 lvalue；
这正是我们既能写 `5 + var2.x`，
也能写 `var2.x= 6` 的原因。

### 运行测试代码

`tests/input58.c` 的输出，
毫不意外地是：

```
12
99
4005
4116
4116
```

我们来看一点生成出来的汇编代码：

```
                                        # var2.y= 'c';
        movq    $99, %r10               # Load 'c' into %r10
        leaq    var2(%rip), %r11        # Get base address of var2 into %r11
        movq    $4, %r12                
        addq    %r11, %r12              # Add 4 to this base address
        movb    %r10b, (%r12)           # Write 'c' into this new address

                                        # printf("%d\n", var2.z);
        leaq    var2(%rip), %r10        # Get base address of var2 into %r11
        movq    $4, %r11
        addq    %r10, %r11              # Add 4 to this base address
        movzbq  (%r11), %r11            # Load byte value from this address into %r11
        movq    %r11, %rsi              # Copy it into %rsi
        leaq    L4(%rip), %r10
        movq    %r10, %rdi
        call    printf@PLT              # and call printf()
```

## 总结与下一步

嗯，
这次 struct 能这么顺利地工作起来，
还真是个挺让人愉快的意外。
不过我很确定，
后面的部分大概率会把这点轻松又补回去。
而且我也很清楚，
当前这个编译器依然有很大局限。
例如它现在还不能处理下面这种代码：

```c
struct foo {
  int x;
  struct foo *next;
};

struct foo *listhead;
struct foo *l;

int main() {
  ...
  l= listhead->next->next;
```

因为这要求连续跟进两层指针，
而现有代码最多只能跟一层。
这个问题后面必须修。

我也觉得现在差不多该明确说一句：
我们后面还得花不少时间让编译器“把事情做对”。
到目前为止，
我主要是在往里面塞功能，
而且每次只做到“足以让某一个特定特性跑起来”。
迟早会有一个阶段，
要把这些特化实现统一提升成更通用的实现。
所以这趟旅程后面一定还会有一个专门的“收尾 / 清理（mop up）”阶段。

现在既然 struct 已经基本能用了，
那在编译器编写之旅的下一部分里，
我就准备去加 union。 [下一步](../33_Unions/Readme.md)
