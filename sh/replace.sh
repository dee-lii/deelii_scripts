#!/bin/bash
cd /ql/scripts/ 

sed -i  's/zero205/test/' `grep -rl zero205 ./`
sed -i  's/Aaron-l/test/' `grep -rl Aaron-l ./`
sed -i  's/lsh26/test/' `grep -rl lsh26 ./`
sed -i  's/transfer/test/' `grep -rl transfer ./`
sed -i  's/fastgit/test/' `grep -rl fastgit ./`
sed -i  's/smiek2221/test/' `grep -rl smiek2221 ./`
sed -i  's/jdsharecode/test/g' `grep -rl jdsharecode  ./`
sed -i  's/fatelight/test/g' `grep -rl fatelight  ./`

sed -i "s/$.newShareCodes \= shareCodes/\/\//g" `grep "$.newShareCodes \= shareCodes" -rl  ./*`
sed -i "s/$.newShareCodes \= inviteCodes/\/\//g" `grep "$.newShareCodes \= inviteCodes" -rl  ./*`

sed -i "s/newShareCodes \= shareCodes/\/\//g" `grep "newShareCodes \= shareCodes" -rl  ./*`
sed -i "s/newShareCodes \= inviteCodes/\/\//g" `grep "newShareCodes \= inviteCodes" -rl  ./*`

#sed -i "s/inviteCodes\[tempIndex\]/\$\.shareCodesArr\[0\]/g" `grep "inviteCodes\[tempIndex\]" -rl  ./`
#sed -i "s/shareCodes\[tempIndex\]/\$\.shareCodesArr\[0\]/g" `grep "shareCodes\[tempIndex\]" -rl  ./`
