// Запрет запросов на сексуальный и жестокий контент до генерации — правила Google Play об ИИ-контенте
// (18.11 рецензент проверял «Make it more spicy»). Та же проверка стоит на сервере в generate-image.
// идея: вынести список в system_config, чтобы дополнять без выкладки.

const L = '(?<![\\p{L}\\p{N}])'; // начало слова (\b не работает с кириллицей)

const BLOCKED: RegExp[] = [
  // английский
  // бельё, соски, интим-гигиена — обычные товары селлеров, их не трогаем
  new RegExp(`${L}(nude|nudes|nudity|naked|nsfw|porn\\w*|xxx|sex|sexy|sexual\\w*|erotic\\w*|hentai|fetish\\w*|topless|bottomless|undress\\w*|unclothed|striptease|stripper|stripping|boobs?|tits|nipples?|genitals?|penis|vagina|onlyfans|seductive|horny|orgasm\\w*|bdsm|lewd|r34|rule ?34)(?![\\p{L}])`, 'iu'),
  new RegExp(`${L}(gore|dismember\\w*|decapitat\\w*|beheading|mutilat\\w*|corpse|dead body)(?![\\p{L}])`, 'iu'),
  // пересказы раздевания — так проверял рецензент Google 25.11 («with nothing on», «see through top»)
  // бельё, купальники, духи (sensual) — товары селлеров: сами слова не трогаем, только «раздеть / прозрачное / без одежды»
  new RegExp(`${L}(sexier|sexiest|breasts|cleavage|busty|upskirt|nip ?slip|skimpy|scantily|strip(ped)? (her|him|them))(?![\\p{L}])`, 'iu'),
  new RegExp(`${L}((with|wearing|wears) nothing on(?! (it|its|the|top|a|an|this|that|there)(?![\\p{L}]))|nothing on (her|him)(?! (face|mind|plate|phone|screen|desk|table)(?![\\p{L}]))|(no|without( any)?) (clothes|clothing)(?! (brand|store|shop|logo|tag|rack|line)s?(?![\\p{L}])))(?![\\p{L}])`, 'iu'),
  new RegExp(`${L}(see[- ]?through|transparent|sheer|wet|revealing) (top|shirt|t-?shirt|blouse|dress|bra|clothes|clothing|outfit|lingerie|underwear|bikini|swimsuit|tank top|bodysuit|nightie|nightgown|robe|skirt)s?(?![\\p{L}])`, 'iu'),
  new RegExp(`${L}(take|takes|took|taking|remove|removes|removed|removing) (off )?(her|his|their|all)( \\p{L}+)? (clothes|clothing|top|shirt|t-?shirt|blouse|bra|dress|bikini|swimsuit|underwear|panties|skirt)(?![\\p{L}])`, 'iu'),
  new RegExp(`${L}(less|fewer) (clothes|clothing)(?![\\p{L}])|${L}show(s|ing)? (some |more |a lot of )?skin(?![\\p{L}])(?! ?(care|cream|tone|type|texture|product|routine))|${L}bare[- ](chest|chested|breasts?|butt)(?![\\p{L}])`, 'iu'),
  new RegExp(`${L}(make|makes|making|made) (her|him|them|the \\p{L}+) (look )?(hotter|sexier|more revealing|more seductive)(?![\\p{L}])`, 'iu'),
  // русский / казахский (корни)
  // «пошлина» не задеваем: только формы «пошлый/пошлая/пошлость»
  new RegExp(`${L}(голы[йеях]|гол(ая|ую|ой)|обнаж\\p{L}*|раздет\\p{L}*|раздень\\p{L}*|раздеть\\p{L}*|порн\\p{L}*|секс\\p{L}*|эрот\\p{L}*|сиськ\\p{L}*|пошл(ый|ая|ое|ые|ого|ую|ост\\p{L}*|ятин\\p{L}*)|похаб\\p{L}*|стриптиз\\p{L}*|без одежды|жалаңаш\\p{L}*)`, 'iu'),
  new RegExp(`${L}(расчлен\\p{L}*|обезглав\\p{L}*|труп(ы|ов|а|ом|ами)?(?![\\p{L}])|кровав\\p{L}* месив\\p{L}*)`, 'iu'),
  new RegExp(`${L}(полугол\\p{L}*|наг(ая|ой|ую|ие|им|их|ишом)(?![\\p{L}])|нагот\\p{L}*|без (белья|трусов|лифчика|бюстгальтера|купальника)|киімсіз\\p{L}*|шешін\\p{L}*)`, 'iu'),
  // «снимок одежды» / «снять каталог» не задеваем: только «сними(те)» или «снять с неё»
  new RegExp(`${L}((сними|снимите)( с (неё|нее|него|них|себя))?|(снять|сняла|снял|сняли|снимает|снимают|снимая)( всю)? с (неё|нее|него|них|себя))( всю| её| ее| его)? (одежд|кофт|футболк|плать|лифчик|бюстгальтер|трус|бель|топ|блузк|купальник)\\p{L}*`, 'iu'),
  new RegExp(`${L}(прозрачн|откровенн|мокр)\\p{L}* (кофт|блуз|майк|футболк|плать|топ|одежд|бель|ночнушк|рубашк|наряд|купальник)\\p{L}*`, 'iu'),
];

// «spicy» — типичная проверка рецензента; про еду (острый соус, крылышки) — можно.
const SPICY = new RegExp(`${L}spic(y|ier|iest)(?![\\p{L}])`, 'iu');
const FOOD = new RegExp(`${L}(food|dish|sauce|chicken|wings?|pepper|chil[il]|noodles?|ramen|pizza|burger|curry|taco|soup|snack|meal|menu|restaurant|cafe|блюд\\p{L}*|соус\\p{L}*|еда|еды|кухн\\p{L}*|меню|ресторан\\p{L}*|кафе)`, 'iu');

export function isPromptBlocked(text?: string | null): boolean {
  // «Avoid: nudity» — это запрет, а не просьба: хвост после «Avoid:» не проверяем
  const t = (text || '').split(/[.,]?\s*Avoid:/i)[0].trim();
  if (!t) return false;
  if (BLOCKED.some(re => re.test(t))) return true;
  return SPICY.test(t) && !FOOD.test(t);
}

export function blockedPromptMessage(language?: string): string {
  if (language === 'ru') return 'Такой запрос нельзя: сексуальный или жестокий контент запрещён правилами. Измените описание.';
  if (language === 'kz') return 'Мұндай сұрауға болмайды: жыныстық немесе қатыгез мазмұнға тыйым салынған. Сипаттаманы өзгертіңіз.';
  return 'This request is not allowed: sexual or violent content is prohibited. Please change your description.';
}
