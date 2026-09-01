%{
#include "syntax.tab.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int yycolumn = 1;
extern int has_error;
int lexer_error_just_happened = 0;

#define YY_USER_ACTION \
    yylloc.first_line = yylineno; \
    yylloc.last_line = yylineno; \
    yylloc.first_column = yycolumn; \
    yylloc.last_column = yycolumn + yyleng - 1; \
    yycolumn += yyleng;
%}

%option yylineno
%option noyywrap

digit       [0-9]
letter      [a-zA-Z_]
id          {letter}({letter}|{digit})*
int_oct_legal  0[0-7]+
int_oct_illegal 0[0-9]+
int_hex_legal  0[xX][0-9a-fA-F]+
int_hex_illegal 0[xX][0-9a-fA-F]*[g-zG-Z_][a-zA-Z0-9_]*
int_dec     {digit}+
float_dec   {digit}+\.{digit}+
float_exp_illegal_1 {digit}+\.{digit}*[eE][+-]?{digit}+[a-zA-Z0-9_]*
float_exp_illegal_2 {digit}+[eE][+-]?{digit}+[a-zA-Z0-9_]*

%%

"int"           { yylval.str = strdup(yytext); return TYPE; }
"float"         { yylval.str = strdup(yytext); return TYPE; }
"if"            { return IF; }
"else"          { return ELSE; }
"while"         { return WHILE; }
"return"        { return RETURN; }
"struct"        { return STRUCT; }

{int_oct_legal}   { yylval.int_val = strtol(yytext, NULL, 8); return INT; }
{int_oct_illegal} { has_error = 1; lexer_error_just_happened = 1; printf("Error type A at Line %d: Illegal octal number '%s'.\n", yylineno, yytext); yylval.int_val = 0; return INT; }
{int_hex_legal}   { yylval.int_val = strtol(yytext, NULL, 16); return INT; }
{int_hex_illegal} { has_error = 1; lexer_error_just_happened = 1; printf("Error type A at Line %d: Illegal hexadecimal number '%s'.\n", yylineno, yytext); yylval.int_val = 0; return INT; }
"0x"|"0X"         { has_error = 1; lexer_error_just_happened = 1; printf("Error type A at Line %d: Illegal hexadecimal number '%s'.\n", yylineno, yytext); yylval.int_val = 0; return INT; }

{float_exp_illegal_1} { has_error = 1; lexer_error_just_happened = 1; printf("Error type A at Line %d: Illegal floating point number '%s'.\n", yylineno, yytext); yylval.float_val = 0.0; return FLOAT; }
{float_exp_illegal_2} { has_error = 1; lexer_error_just_happened = 1; printf("Error type A at Line %d: Illegal floating point number '%s'.\n", yylineno, yytext); yylval.float_val = 0.0; return FLOAT; }

{float_dec}     { yylval.float_val = atof(yytext); return FLOAT; }
{int_dec}       { yylval.int_val = atoi(yytext); return INT; }

{id}            { yylval.str = strdup(yytext); return ID; }

"//".*                      { has_error = 1; lexer_error_just_happened = 1; printf("Error type A at Line %d: Illegal character '/'.\n", yylineno); return SEMI; }
"/"\*([^*]|\*+[^*/])*\*+"/" { has_error = 1; lexer_error_just_happened = 1; printf("Error type A at Line %d: Illegal character '/'.\n", yylineno); return SEMI; }

"+"             { return PLUS; }
"-"             { return MINUS; }
"*"             { return STAR; }
"/"             { return DIV; }
"="             { return ASSIGNOP; }
"=="            { yylval.str = strdup(yytext); return RELOP; }
"!="            { yylval.str = strdup(yytext); return RELOP; }
"!"             { return NOT; }
"<"             { yylval.str = strdup(yytext); return RELOP; }
"<="            { yylval.str = strdup(yytext); return RELOP; }
">"             { yylval.str = strdup(yytext); return RELOP; }
">="            { yylval.str = strdup(yytext); return RELOP; }
"&&"            { return AND; }
"||"            { return OR; }
";"             { return SEMI; }
","             { return COMMA; }
"("             { return LP; }
")"             { return RP; }
"{"             { return LC; }
"}"             { return RC; }
"["             { return LB; }
"]"             { return RB; }
"."             { return DOT; }

[ \t\r\n]+      { /* skip whitespace */ }

.               { has_error = 1; lexer_error_just_happened = 1; printf("Error type A at Line %d: Illegal character '%s'.\n", yylineno, yytext); return SEMI; }

%%
