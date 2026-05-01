# 第 47 部分：`sizeof()` 的一个子集

在一个真正的 C 编译器里，
`sizeof()` 运算符可以返回下面两类对象的字节大小：

 + 一个类型定义
 + 一个表达式的类型

我检查了一下我们当前编译器自己的代码，
发现我只用到了上面第一种，
也就是“对类型定义求 `sizeof()`”。
所以我现在只实现这一半。
这样事情就简单不少，
因为我们可以直接假设：
`sizeof()` 括号里的东西一定是一个类型定义。

## 新 token 与关键字

我们需要一个新的关键字 `"sizeof"`，
以及一个新的 token：`T_SIZEOF`。
按惯例，
具体对 `scan.c` 的改动
我就不展开贴了，
你可以自己去看。

不过在新增 token 时，
我们还必须顺手更新下面这张表：

```c
// List of token strings, for debugging purposes
char *Tstring[] = {
  "EOF", "=", "+=", "-=", "*=", "/=",
  "||", "&&", "|", "^", "&",
  "==", "!=", ",", ">", "<=", ">=", "<<", ">>",
  "+", "-", "*", "/", "++", "--", "~", "!",
  "void", "char", "int", "long",
  "if", "else", "while", "for", "return",
  "struct", "union", "enum", "typedef",
  "extern", "break", "continue", "switch",
  "case", "default", "sizeof",
  "intlit", "strlit", ";", "identifier",
  "{", "}", "(", ")", "[", "]", ",", ".",
  "->", ":"
};
```

我一开始就忘了改这里，
结果调试时，
凡是 `"default"` 之后的那些 token，
显示出来的名字全都不对。
有点蠢。

## 对解析器的修改

`sizeof()` 是表达式解析的一部分，
因为它会“吃下一个东西并产出一个新值”。
例如我们完全可以写：

```c
  int x= 43 + sizeof(char);
```

所以，
我们需要去修改 `expr.c`
把 `sizeof()` 加进去。
它不是二元运算符，
也不是前缀或后缀运算符，
因此最适合安放它的位置，
就是“解析主表达式（primary expression）”的那一层。

事实上，
等我把几个自己造成的蠢 bug 修掉之后，
真正为了支持 `sizeof()`
所新增的代码并不多。
如下：

```c
// Parse a primary factor and return an
// AST node representing it.
static struct ASTnode *primary(void) {
  struct ASTnode *n;
  int id;
  int type=0;
  int size, class;
  struct symtable *ctype;

  switch (Token.token) {
  case T_SIZEOF:
    // Skip the T_SIZEOF and ensure we have a left parenthesis
    scan(&Token);
    if (Token.token != T_LPAREN)
      fatal("Left parenthesis expected after sizeof");
    scan(&Token);

    // Get the type inside the parentheses
    type= parse_stars(parse_type(&ctype, &class));
    // Get the type's size
    size= typesize(type, ctype);
    rparen();
    // Return a leaf node int literal with the size
    return (mkastleaf(A_INTLIT, P_INT, NULL, size));
    ...
  }
  ...
}
```

我们本来就已经有一个 `parse_type()`，
用来解析类型定义；
也已经有 `parse_stars()`，
用来处理后续跟着的星号；
最后我们还已经有了 `typesize()`，
能返回某个类型占用的字节数。

因此这里真正要做的，
无非就是把相关 token 读进来，
调用这三个现成函数，
再构造一个带整数字面量值的叶子 AST 节点返回出去。

没错，
我知道 `sizeof()` 其实还有一堆细节与边角行为。
不过我还是继续坚持
“KISS principle”，
先做到足够让编译器能自举所需的程度。

## 测试新代码

`tests/input115.c`
里放了一组测试，
用来覆盖基本类型、一个指针，
以及编译器自身用到的几个结构体：

```c
struct foo { int x; char y; long z; }; 
typedef struct foo blah;

int main() {
  printf("%ld\n", sizeof(char));
  printf("%ld\n", sizeof(int));
  printf("%ld\n", sizeof(long));
  printf("%ld\n", sizeof(char *));
  printf("%ld\n", sizeof(blah));
  printf("%ld\n", sizeof(struct symtable));
  printf("%ld\n", sizeof(struct ASTnode));
  return(0);
}
```

当前编译器输出的是：

```
1
4
8
8
13
64
48
```

我现在在想，
我们是不是应该把 `struct foo`
补齐到 16 字节，
而不是 13 字节。
这个问题等后面真的撞上时再说吧。

## 总结与下一步

至少就当前编译器所需的功能范围而言，
`sizeof()` 实现起来还算简单。
但如果是一个真正完整的生产级 C 编译器，
`sizeof()` 其实会复杂得多。

在编译器编写之旅的下一部分中，
我会去处理 `static`。 [下一步](../48_Static/Readme.md)
