String pelicanSvgFixture() =>
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 640 480">\n'
    '<title>鹈鹕骑自行车</title><desc>Escaped XML: &amp; &quot;</desc>\n'
    '<g id="bicycle" fill="none" stroke="#34495e" stroke-width="8">'
    '<circle cx="190" cy="350" r="80"/><circle cx="450" cy="350" r="80"/>'
    '<path d="M190 350L285 240L340 350L190 350M285 240L425 220L450 350"/></g>\n'
    '<g id="pelican" fill="#fff4dc" stroke="#304052" stroke-width="4">'
    '<ellipse cx="310" cy="200" rx="70" ry="85"/><circle cx="345" cy="95" r="45"/>'
    '<path fill="#f5b642" d="M375 95L490 110L375 135Z"/>'
    '<circle fill="#18212c" cx="360" cy="82" r="5"/></g>\n'
    '<defs>\n${List.generate(4800, (i) => '<path id="detail-$i" d="M1 1L2 2"/>\n').join()}'
    '</defs></svg>';
