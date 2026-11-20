// Запрет запросов на сексуальный и жестокий контент до генерации — правила Google Play об ИИ-контенте
// (18.11 рецензент проверял «Make it more spicy»). Та же проверка стоит на сервере в generate-image.
// идея: вынести список в system_config, чтобы дополнять без выкладки.

const L = '(?<![\\p{L}\\p{N}])'; // начало слова (\b не работает с кириллицей)

const BLOCKED: RegExp[] = [
  // английский
  // бельё, соски, интим-гигиена — обычные товары селлеров, их не трогаем
  new RegExp(`${L}(nude|nudes|nudity|naked|nsfw|porn\\w*|xxx|sex|sexy|sexual\\w*|erotic\\w*|hentai|fetish\\w*|topless|bottomless|undress\\w*|unclothed|striptease|stripper|stripping|boobs?|tits|nipples?|genitals?|penis|vagina|onlyfans|seductive|horny|orgasm\\w*|bdsm|lewd|r34|rule ?34)(?![\\p{L}])`, 'iu'),
  new RegExp(`${L}(gore|dismember\\w*|decapitat\\w*|beheading|mutilat\\w*|corpse|dead body)(?![\\p{L}])`, 'iu'),
  // русский / казахский (корни)
  // «пошлина» не задеваем: только формы «пошлый/пошлая/пошлость»
  new RegExp(`${L}(голы[йеях]|гол(ая|ую|ой)|обнаж\\p{L}*|раздет\\p{L}*|раздень\\p{L}*|раздеть\\p{L}*|порн\\p{L}*|секс\\p{L}*|эрот\\p{L}*|сиськ\\p{L}*|пошл(ый|ая|ое|ые|ого|ую|ост\\p{L}*|ятин\\p{L}*)|похаб\\p{L}*|стриптиз\\p{L}*|без одежды|жалаңаш\\p{L}*)`, 'iu'),
  new RegExp(`${L}(расчлен\\p{L}*|обезглав\\p{L}*|труп(ы|ов|а|ом|ами)?(?![\\p{L}])|кровав\\p{L}* месив\\p{L}*)`, 'iu'),
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
